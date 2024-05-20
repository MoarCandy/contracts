// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { stdMath } from "forge-std/src/StdMath.sol";

import { BondingERC20TokenFactory } from "src/BondingERC20TokenFactory.sol";
import { ContinuosBondingERC20Token } from "src/ContinuosBondingERC20Token.sol";
import { IContinuousBondingERC20Token } from "src/interfaces/IContinuousBondingERC20Token.sol";
import { IBondingCurve } from "src/interfaces/IBondingCurve.sol";
import { BancorFormula } from "src/BancorCurve/BancorFormula.sol";

contract ContinuosBondingERC20TokenTest is Test {
  BondingERC20TokenFactory internal factory;
  IBondingCurve internal bondingCurve;
  address internal router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
  address internal treasury = makeAddr("treasury");
  address internal owner = makeAddr("owner");
  address internal user = makeAddr("user");
  ContinuosBondingERC20Token internal bondingERC20Token;
  uint256 internal initialETHContribution;
  uint256 internal startingSupply;

  function setUp() public {
    uint256 forkId = vm.createFork(vm.envString("ETH_RPC_URL"), 19876830);
    vm.selectFork(forkId);

    bondingCurve = new BancorFormula();
    factory = new BondingERC20TokenFactory(owner, bondingCurve, treasury);
    bondingERC20Token = ContinuosBondingERC20Token(
      factory.deployBondingERC20Token(router, "ERC20Token", "ERC20", 100, 100)
    );
    initialETHContribution = bondingERC20Token.totalETHContributed();
    startingSupply = bondingERC20Token.STARTING_SUPPLY();
  }

  function testCanBuyToken() public {
    uint256 amount = 100 ether;
    vm.deal(user, amount);
    vm.startPrank(user);

    uint256 beforeBalanceOfBondingToken = bondingERC20Token.balanceOf(user);

    bondingERC20Token.buyTokens{ value: amount }();

    uint256 afterBalanceOfBondingToken = bondingERC20Token.balanceOf(user);
    uint256 tokenPerWei = afterBalanceOfBondingToken / amount;

    assertGt(afterBalanceOfBondingToken, 0);
    assertGt(tokenPerWei, 0);
    assertEq(bondingERC20Token.totalETHContributed(), 99 ether + initialETHContribution); // 1% goes to treasury
    assertEq(bondingERC20Token.treasuryClaimableETH(), 1 ether); // 1% treasury funds
  }

  function testCanBuyTokenTillLiquidityGoal() public {
    vm.deal(user, 1000 ether);
    vm.startPrank(user);

    vm.expectRevert();
    bondingERC20Token.buyTokens{ value: 500 ether }();

    bondingERC20Token.buyTokens{ value: 400 ether }(); //liquidity goal will be (0.99 * 400 = 396) ether now.

    vm.expectRevert();
    bondingERC20Token.buyTokens{ value: 4.5 ether }(); //liquidity goal will be (396 + 0.99 * 4.5 = 400.455) ether now. hence, will revert as exceeded liquidity goal

    vm.expectRevert();
    bondingERC20Token.buyTokens{ value: 4.05 ether }(); //liquidity goal will be (396 + 0.99 * 4.05 = 400.0095) ether now. hence, will revert as exceeded liquidity goal

    bondingERC20Token.buyTokens{ value: 4.04 ether }(); //liquidity goal will be (396 + 0.99 * 4.04 = 399.9996) ether now.
  }

  function testCanBuyTokenFuzz(uint256 amount) public {
    amount = bound(amount, 1, 400 ether);
    vm.deal(user, amount);

    vm.startPrank(user);
    bondingERC20Token.buyTokens{ value: amount }();
  }

  function testPriceIncreasesAfterEachBuy() public {
    uint256 amount = 400 ether;
    uint256 halfAmount = amount / 2;

    vm.deal(user, amount);
    vm.startPrank(user);

    uint256 beforeBalanceOfBondingToken = bondingERC20Token.balanceOf(user);
    bondingERC20Token.buyTokens{ value: halfAmount }();
    uint256 receivedAfterFirstBuy = bondingERC20Token.balanceOf(user);
    uint256 tokenPerWeiForFirstBuy = (receivedAfterFirstBuy * 1e18) / halfAmount;

    bondingERC20Token.buyTokens{ value: halfAmount }();
    uint256 receivedAfterSecondBuy = bondingERC20Token.balanceOf(user) - receivedAfterFirstBuy;
    uint256 tokenPerWeiForSecondBuy = (receivedAfterSecondBuy * 1e18) / halfAmount;
    console2.log(tokenPerWeiForFirstBuy, tokenPerWeiForSecondBuy);
    assertGt(receivedAfterFirstBuy, receivedAfterSecondBuy);
    assertGt(tokenPerWeiForFirstBuy, tokenPerWeiForSecondBuy);
    console2.log(bondingERC20Token.totalSupply());
  }

  function testCanSellToken() public {
    uint256 amount = 100 ether;
    vm.deal(user, amount);
    vm.startPrank(user);

    bondingERC20Token.buyTokens{ value: amount }();

    uint256 balanceOfBondingToken = bondingERC20Token.balanceOf(user);

    uint256 ethBalanceBefore = user.balance;

    uint256 claimableETH = bondingERC20Token.calculateETHAmount(balanceOfBondingToken);

    bondingERC20Token.sellTokens(balanceOfBondingToken);

    uint256 ethReceived = user.balance - ethBalanceBefore;

    assert(_withinRange(ethReceived, 99 ether - (0.01 * 99 ether) - initialETHContribution, 1e14));
    assertEq(bondingERC20Token.totalETHContributed(), initialETHContribution + (99 ether - claimableETH));
    assertEq(bondingERC20Token.totalSupply(), startingSupply);
  }

  function _withinRange(uint256 a, uint256 b, uint256 diff) internal returns (bool) {
    return (stdMath.delta(a, b) <= diff);
  }
}