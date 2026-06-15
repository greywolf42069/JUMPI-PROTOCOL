// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// ══════════════════════════════════════════════════════════════
// Mock ERC20 for testing token routing
// ══════════════════════════════════════════════════════════════

contract MockERC20 {
    string public name = "MockToken";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        require(balanceOf[from] >= amount, "insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Helper contract that can receive ETH
contract ETHReceiver {
    receive() external payable {}
}

// Helper contract that rejects ETH
contract ETHRejecter {
    // no receive or fallback
}

// Reentrancy attacker: receives ETH and tries to reenter routeETH
contract ReentrantETHAttacker {
    IJumpiProtocol public target;
    bool public attacked;

    constructor(IJumpiProtocol _target) {
        target = _target;
    }

    function attack() external payable {
        target.routeETH{value: msg.value}(address(this));
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Try to reenter — should fail due to reentrancy guard
            target.routeETH{value: msg.value}(address(this));
        }
    }
}

// Delegatecall attacker: tries to delegatecall into the protocol
contract DelegateCaller {
    function tryDelegatecall(address target, bytes calldata data) external returns (bool success, bytes memory result) {
        (success, result) = target.delegatecall(data);
    }
}

// ERC20 that reverts on zero-amount transfers (mirrors real-world tokens like BNT, LEND)
contract ZeroRevertToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(amount > 0, "zero transfer rejected");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        require(balanceOf[from] >= amount, "insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ══════════════════════════════════════════════════════════════
// Interface
// ══════════════════════════════════════════════════════════════

interface IJumpiProtocol {
    // Public
    function routeToken(address token, address to, uint256 amount) external returns (bool);
    function routeETH(address to) external payable returns (bool);

    // Admin
    function sweepETH() external returns (bool);
    function sweepToken(address token) external returns (bool);
    function setPaused(bool status) external returns (bool);
    function setWhitelistEnabled(bool status) external returns (bool);
    function whitelistToken(address token, bool status) external returns (bool);
    function setMaxFee(uint256 maxFee) external returns (bool);

    // View
    function getFeeRecipient() external view returns (address);
    function getFeeBps() external view returns (uint256);
    function isPaused() external view returns (bool);
    function isWhitelisted(address token) external view returns (bool);
    function getMaxFee() external view returns (uint256);
    function isWhitelistEnabled() external view returns (bool);

    // Events
    event TokenRouted(address indexed token, address indexed from, address indexed to, uint256 net, uint256 fee);
    event ETHRouted(address indexed from, address indexed to, uint256 net, uint256 fee);
    event Swept(address indexed token, uint256 amount);
    event ETHSwept(uint256 amount);
    event SetPaused(bool status);
    event SetWhitelistEnabled(bool status);
    event TokenWhitelistUpdated(address indexed token, bool status);
    event MaxFeeUpdated(uint256 maxFee);
}

// ══════════════════════════════════════════════════════════════
// Test Suite
// ══════════════════════════════════════════════════════════════

contract JumpiProtocolTest is Test {
    IJumpiProtocol protocol;
    MockERC20 token;
    MockERC20 token2;

    address deployer;
    address alice;
    address bob;
    address charlie;

    uint256 constant FEE_BPS = 50;
    uint256 constant BPS_DENOMINATOR = 10000;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy protocol from Huff bytecode as deployer
        string memory bytecodeHex = vm.readFile("bytecode.txt");
        bytes memory bytecode = vm.parseBytes(bytecodeHex);
        address deployed;
        vm.prank(deployer);
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "Deploy failed");
        protocol = IJumpiProtocol(deployed);

        // Deploy mock tokens
        token = new MockERC20();
        token2 = new MockERC20();

        // Fund alice with ETH and tokens
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 10 ether);
        token.mint(alice, 1_000_000e18);
        token2.mint(alice, 500_000e18);

        // Alice approves protocol for both tokens
        vm.startPrank(alice);
        token.approve(address(protocol), type(uint256).max);
        token2.approve(address(protocol), type(uint256).max);
        vm.stopPrank();
    }

    // Helper: compute expected fee
    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount * FEE_BPS / BPS_DENOMINATOR;
    }

    // ═══════════════ SMOKE TESTS (8) ═══════════════

    function test_smoke_deployment() public view {
        assertTrue(address(protocol) != address(0));
    }

    function test_smoke_hasCode() public view {
        assertTrue(address(protocol).code.length > 0);
    }

    function test_smoke_feeRecipient() public view {
        assertEq(protocol.getFeeRecipient(), deployer);
    }

    function test_smoke_feeBps() public view {
        assertEq(protocol.getFeeBps(), 50);
    }

    function test_smoke_emptyCalldata_reverts() public {
        (bool ok,) = address(protocol).call("");
        assertFalse(ok);
    }

    function test_smoke_shortCalldata_reverts() public {
        (bool ok,) = address(protocol).call(hex"abcdef");
        assertFalse(ok);
    }

    function test_smoke_unknownSelector_reverts() public {
        (bool ok,) = address(protocol).call(hex"deadbeef");
        assertFalse(ok);
    }

    function test_smoke_directETH_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(protocol).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ═══════════════ routeToken UNIT TESTS (12) ═══════════════

    function test_routeToken_basic() public {
        uint256 amount = 10_000e18;
        vm.prank(alice);
        bool ok = protocol.routeToken(address(token), bob, amount);
        assertTrue(ok);
    }

    function test_routeToken_correctFee() public {
        uint256 amount = 10_000e18;
        uint256 expectedFee = _fee(amount); // 50e18
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer) - deployerBefore, expectedFee);
    }

    function test_routeToken_correctNet() public {
        uint256 amount = 10_000e18;
        uint256 expectedNet = amount - _fee(amount);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(bob) - bobBefore, expectedNet);
    }

    function test_routeToken_callerDeducted() public {
        uint256 amount = 10_000e18;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(aliceBefore - token.balanceOf(alice), amount);
    }

    function test_routeToken_zeroToken_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(0), bob, 1000)
        );
        assertFalse(ok);
    }

    function test_routeToken_zeroTo_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), address(0), 1000)
        );
        assertFalse(ok);
    }

    function test_routeToken_zeroAmount_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 0)
        );
        assertFalse(ok);
    }

    function test_routeToken_noApproval_reverts() public {
        token.mint(charlie, 1000e18);
        // charlie has NOT approved protocol
        vm.prank(charlie);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
    }

    function test_routeToken_insufficientBalance_reverts() public {
        // alice only has 1M tokens, try to route 2M
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 2_000_000e18)
        );
        assertFalse(ok);
    }

    function test_routeToken_exactFee_10000() public {
        // 10000 tokens → fee = 50, net = 9950
        uint256 amount = 10000;
        token.mint(alice, amount); // extra mint

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer), 50);
        assertEq(token.balanceOf(bob), 9950);
    }

    function test_routeToken_smallAmount_zeroFee() public {
        // 100 tokens → fee = 0, net = 100
        uint256 amount = 100;
        token.mint(alice, amount);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(bob) - bobBefore, 100); // all goes to recipient
        assertEq(token.balanceOf(deployer), 0); // no fee
    }

    function test_routeToken_multipleRoutes() public {
        uint256 amount = 1000e18;
        vm.startPrank(alice);
        protocol.routeToken(address(token), bob, amount);
        protocol.routeToken(address(token), charlie, amount);
        vm.stopPrank();

        uint256 expectedFee = _fee(amount);
        assertEq(token.balanceOf(deployer), expectedFee * 2);
    }

    // ═══════════════ routeETH UNIT TESTS (10) ═══════════════

    function test_routeETH_basic() public {
        vm.prank(alice);
        bool ok = protocol.routeETH{value: 1 ether}(bob);
        assertTrue(ok);
    }

    function test_routeETH_correctFee() public {
        uint256 amount = 10 ether;
        uint256 expectedFee = _fee(amount); // 0.05 ether

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(address(protocol).balance, expectedFee);
    }

    function test_routeETH_correctNet() public {
        uint256 amount = 10 ether;
        uint256 expectedNet = amount - _fee(amount);
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(bob.balance - bobBefore, expectedNet);
    }

    function test_routeETH_callerDeducted() public {
        uint256 amount = 1 ether;
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertTrue(aliceBefore - alice.balance >= amount);
    }

    function test_routeETH_zeroTo_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.routeETH.selector, address(0))
        );
        assertFalse(ok);
    }

    function test_routeETH_zeroValue_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 0}(
            abi.encodeWithSelector(IJumpiProtocol.routeETH.selector, bob)
        );
        assertFalse(ok);
    }

    function test_routeETH_exactFee_10000wei() public {
        uint256 amount = 10000;
        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(address(protocol).balance, 50); // 0.5% of 10000
    }

    function test_routeETH_smallAmount_zeroFee() public {
        uint256 amount = 100;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(bob.balance - bobBefore, 100);
        assertEq(address(protocol).balance, 0);
    }

    function test_routeETH_multipleRoutes_feeAccumulates() public {
        uint256 amount = 1 ether;
        vm.startPrank(alice);
        protocol.routeETH{value: amount}(bob);
        protocol.routeETH{value: amount}(charlie);
        vm.stopPrank();

        assertEq(address(protocol).balance, _fee(amount) * 2);
    }

    function test_routeETH_largeAmount() public {
        uint256 amount = 100 ether;
        uint256 expectedFee = _fee(amount);

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(address(protocol).balance, expectedFee);
        assertEq(bob.balance - 10 ether, amount - expectedFee);
    }

    // ═══════════════ SWEEP UNIT TESTS (8) ═══════════════

    function test_sweepETH_basic() public {
        vm.prank(alice);
        protocol.routeETH{value: 10 ether}(bob);

        uint256 fee = address(protocol).balance;
        assertTrue(fee > 0);

        uint256 deployerBefore = deployer.balance;
        vm.prank(deployer);
        bool ok = protocol.sweepETH();
        assertTrue(ok);

        assertEq(deployer.balance - deployerBefore, fee);
        assertEq(address(protocol).balance, 0);
    }

    function test_sweepETH_nonDeployer_reverts() public {
        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(bob);

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.sweepETH.selector)
        );
        assertFalse(ok);
    }

    function test_sweepETH_nothingToSweep_reverts() public {
        vm.prank(deployer);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.sweepETH.selector)
        );
        assertFalse(ok);
    }

    function test_sweepETH_afterMultipleRoutes() public {
        vm.startPrank(alice);
        protocol.routeETH{value: 2 ether}(bob);
        protocol.routeETH{value: 3 ether}(charlie);
        vm.stopPrank();

        uint256 expectedFees = _fee(2 ether) + _fee(3 ether);
        assertEq(address(protocol).balance, expectedFees);

        vm.prank(deployer);
        protocol.sweepETH();

        assertEq(address(protocol).balance, 0);
    }

    function test_sweepToken_basic() public {
        token.mint(address(protocol), 1000e18);

        uint256 deployerBefore = token.balanceOf(deployer);
        vm.prank(deployer);
        bool ok = protocol.sweepToken(address(token));
        assertTrue(ok);

        assertEq(token.balanceOf(deployer) - deployerBefore, 1000e18);
        assertEq(token.balanceOf(address(protocol)), 0);
    }

    function test_sweepToken_nonDeployer_reverts() public {
        token.mint(address(protocol), 1000e18);

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.sweepToken.selector, address(token))
        );
        assertFalse(ok);
    }

    function test_sweepToken_nothingToSweep_reverts() public {
        vm.prank(deployer);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.sweepToken.selector, address(token))
        );
        assertFalse(ok);
    }

    function test_sweepToken_zeroAddress_reverts() public {
        vm.prank(deployer);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.sweepToken.selector, address(0))
        );
        assertFalse(ok);
    }

    // ═══════════════ EVENT TESTS (6) ═══════════════

    function test_event_tokenRouted() public {
        uint256 amount = 1000e18;
        uint256 expectedFee = _fee(amount);
        uint256 expectedNet = amount - expectedFee;

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.TokenRouted(address(token), alice, bob, expectedNet, expectedFee);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);
    }

    function test_event_ethRouted() public {
        uint256 amount = 1 ether;
        uint256 expectedFee = _fee(amount);
        uint256 expectedNet = amount - expectedFee;

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.ETHRouted(alice, bob, expectedNet, expectedFee);

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);
    }

    function test_event_swept() public {
        token.mint(address(protocol), 500e18);

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.Swept(address(token), 500e18);

        vm.prank(deployer);
        protocol.sweepToken(address(token));
    }

    function test_event_ethSwept() public {
        vm.prank(alice);
        protocol.routeETH{value: 10 ether}(bob);
        uint256 fee = address(protocol).balance;

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.ETHSwept(fee);

        vm.prank(deployer);
        protocol.sweepETH();
    }

    function test_event_tokenRouted_multipleEmissions() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.TokenRouted(address(token), alice, bob, amount1 - _fee(amount1), _fee(amount1));

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount1);

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.TokenRouted(address(token), alice, charlie, amount2 - _fee(amount2), _fee(amount2));

        vm.prank(alice);
        protocol.routeToken(address(token), charlie, amount2);
    }

    function test_event_ethRouted_multipleEmissions() public {
        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.ETHRouted(alice, bob, 1 ether - _fee(1 ether), _fee(1 ether));

        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(bob);

        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.ETHRouted(alice, charlie, 2 ether - _fee(2 ether), _fee(2 ether));

        vm.prank(alice);
        protocol.routeETH{value: 2 ether}(charlie);
    }

    // ═══════════════ FEE MATH TESTS (6) ═══════════════

    function test_feeMath_exact05percent() public pure {
        uint256 amount = 1_000_000;
        uint256 fee = amount * 50 / 10000;
        assertEq(fee, 5000);
    }

    function test_feeMath_roundDown() public pure {
        assertEq(uint256(201) * 50 / 10000, uint256(1));
        assertEq(uint256(399) * 50 / 10000, uint256(1));
    }

    function test_feeMath_zeroFeeForTinyAmount() public pure {
        assertEq(uint256(199) * 50 / 10000, uint256(0));
        assertEq(uint256(100) * 50 / 10000, uint256(0));
        assertEq(uint256(1) * 50 / 10000, uint256(0));
    }

    function test_feeMath_netPlusFeeEqualsAmount() public pure {
        uint256 amount = 123456789;
        uint256 fee = amount * 50 / 10000;
        uint256 net = amount - fee;
        assertEq(net + fee, amount);
    }

    function test_feeMath_oneWei() public {
        token.mint(alice, 1);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, 1);

        assertEq(token.balanceOf(bob) - bobBefore, 1);
    }

    function test_feeMath_largeAmount() public pure {
        assertEq(uint256(1e18) * 50 / 10000, uint256(5e15));
        assertEq(uint256(100e18) * 50 / 10000, uint256(5e17));
    }

    // ═══════════════ FUZZ TESTS (6) ═══════════════

    function test_fuzz_routeToken(uint256 amount) public {
        amount = bound(amount, 1, 500_000e18);
        uint256 expectedFee = amount * 50 / 10000;
        uint256 expectedNet = amount - expectedFee;
        uint256 bobBefore = token.balanceOf(bob);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(bob) - bobBefore, expectedNet);
        assertEq(token.balanceOf(deployer) - deployerBefore, expectedFee);
    }

    function test_fuzz_routeETH(uint256 amount) public {
        amount = bound(amount, 1, 500 ether);
        uint256 expectedFee = amount * 50 / 10000;
        uint256 expectedNet = amount - expectedFee;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(bob.balance - bobBefore, expectedNet);
        assertEq(address(protocol).balance, expectedFee);
    }

    function test_fuzz_feePlusNetEqualsAmount(uint256 amount) public pure {
        amount = bound(amount, 1, type(uint128).max);
        uint256 fee = amount * 50 / 10000;
        uint256 net = amount - fee;
        assertEq(net + fee, amount);
    }

    function test_fuzz_feeNeverExceedsHalfPercent(uint256 amount) public pure {
        amount = bound(amount, 200, type(uint128).max);
        uint256 fee = amount * 50 / 10000;
        assertTrue(fee * 10000 <= amount * 50);
    }

    function test_fuzz_multipleRoutes(uint8 count) public {
        count = uint8(bound(count, 1, 10));
        uint256 amount = 1000e18;
        uint256 totalFee;

        vm.startPrank(alice);
        for (uint8 i = 0; i < count; i++) {
            protocol.routeToken(address(token), bob, amount);
            totalFee += _fee(amount);
        }
        vm.stopPrank();

        assertEq(token.balanceOf(deployer), totalFee);
    }

    function test_fuzz_routeETH_differentAmounts(uint128 a, uint128 b) public {
        uint256 amount1 = bound(a, 1, 100 ether);
        uint256 amount2 = bound(b, 1, 100 ether);

        vm.startPrank(alice);
        protocol.routeETH{value: amount1}(bob);
        protocol.routeETH{value: amount2}(charlie);
        vm.stopPrank();

        uint256 expectedTotalFee = _fee(amount1) + _fee(amount2);
        assertEq(address(protocol).balance, expectedTotalFee);
    }

    // ═══════════════ CHAOS TESTS (8) ═══════════════

    function test_chaos_routeTokenToSelf() public {
        uint256 amount = 1000e18;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        protocol.routeToken(address(token), alice, amount);

        uint256 fee = _fee(amount);
        assertEq(aliceBefore - token.balanceOf(alice), fee);
    }

    function test_chaos_routeTokenToFeeRecipient() public {
        uint256 amount = 1000e18;

        vm.prank(alice);
        protocol.routeToken(address(token), deployer, amount);

        assertEq(token.balanceOf(deployer), amount);
    }

    function test_chaos_routeETHToSelf() public {
        uint256 amount = 1 ether;

        vm.prank(alice);
        protocol.routeETH{value: amount}(alice);

        uint256 fee = _fee(amount);
        assertEq(address(protocol).balance, fee);
    }

    function test_chaos_routeETHToFeeRecipient() public {
        uint256 amount = 1 ether;
        uint256 deployerBefore = deployer.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(deployer);

        uint256 fee = _fee(amount);
        uint256 net = amount - fee;
        assertEq(deployer.balance - deployerBefore, net);
        assertEq(address(protocol).balance, fee);
    }

    function test_chaos_multipleTokens() public {
        uint256 amount = 1000e18;

        vm.startPrank(alice);
        protocol.routeToken(address(token), bob, amount);
        protocol.routeToken(address(token2), charlie, amount);
        vm.stopPrank();

        uint256 fee = _fee(amount);
        assertEq(token.balanceOf(deployer), fee);
        assertEq(token2.balanceOf(deployer), fee);
    }

    function test_chaos_mixedTokenAndETH() public {
        vm.startPrank(alice);
        protocol.routeToken(address(token), bob, 1000e18);
        protocol.routeETH{value: 1 ether}(charlie);
        vm.stopPrank();

        assertEq(token.balanceOf(deployer), _fee(1000e18));
        assertEq(address(protocol).balance, _fee(1 ether));
    }

    function test_chaos_maxApproval() public {
        vm.prank(alice);
        protocol.routeToken(address(token), bob, 100_000e18);

        vm.prank(alice);
        protocol.routeToken(address(token), charlie, 100_000e18);
    }

    function test_chaos_routeToContract() public {
        ETHReceiver receiver = new ETHReceiver();

        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(address(receiver));

        uint256 fee = _fee(1 ether);
        assertEq(address(receiver).balance, 1 ether - fee);
    }

    // ═══════════════ MONKEY TESTS (6) ═══════════════

    function test_monkey_fullTokenLifecycle() public {
        uint256 amount = 5000e18;
        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer), _fee(amount));
        assertEq(token.balanceOf(bob), amount - _fee(amount));
        assertEq(token.balanceOf(alice), 1_000_000e18 - amount);
    }

    function test_monkey_fullETHLifecycle() public {
        uint256 amount = 5 ether;
        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        uint256 fee = _fee(amount);
        assertEq(address(protocol).balance, fee);

        uint256 deployerBefore = deployer.balance;
        vm.prank(deployer);
        protocol.sweepETH();

        assertEq(deployer.balance - deployerBefore, fee);
        assertEq(address(protocol).balance, 0);
    }

    function test_monkey_multiUserRouting() public {
        token.mint(bob, 5000e18);
        vm.prank(bob);
        token.approve(address(protocol), type(uint256).max);

        vm.prank(alice);
        protocol.routeToken(address(token), charlie, 1000e18);

        vm.prank(bob);
        protocol.routeToken(address(token), charlie, 2000e18);

        uint256 totalFees = _fee(1000e18) + _fee(2000e18);
        assertEq(token.balanceOf(deployer), totalFees);
    }

    function test_monkey_repeatedSweeps() public {
        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(bob);

        vm.prank(deployer);
        protocol.sweepETH();

        vm.prank(alice);
        protocol.routeETH{value: 2 ether}(charlie);

        vm.prank(deployer);
        protocol.sweepETH();

        assertEq(address(protocol).balance, 0);
    }

    function test_monkey_tokenAndETHCombined() public {
        vm.startPrank(alice);
        protocol.routeToken(address(token), bob, 10_000e18);
        protocol.routeToken(address(token2), charlie, 5_000e18);
        protocol.routeETH{value: 10 ether}(bob);
        vm.stopPrank();

        assertEq(token.balanceOf(deployer), _fee(10_000e18));
        assertEq(token2.balanceOf(deployer), _fee(5_000e18));
        assertEq(address(protocol).balance, _fee(10 ether));

        vm.prank(deployer);
        protocol.sweepETH();
        assertEq(address(protocol).balance, 0);
    }

    function test_monkey_stressRouting() public {
        uint256 routeAmount = 10e18;

        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            protocol.routeToken(address(token), bob, routeAmount);
        }
        vm.stopPrank();

        uint256 totalFee = _fee(routeAmount) * 20;
        assertEq(token.balanceOf(deployer), totalFee);
        assertEq(token.balanceOf(bob), (routeAmount - _fee(routeAmount)) * 20);
    }

    // ═══════════════ INVARIANT TESTS (4) ═══════════════

    function test_invariant_feePlusNetEqualsAmount() public {
        uint256 amount = 777_777e18;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        uint256 aliceDelta = aliceBefore - token.balanceOf(alice);
        uint256 bobDelta = token.balanceOf(bob) - bobBefore;
        uint256 deployerDelta = token.balanceOf(deployer) - deployerBefore;

        assertEq(aliceDelta, amount);
        assertEq(bobDelta + deployerDelta, amount);
    }

    function test_invariant_ethFeePlusNetEqualsValue() public {
        uint256 amount = 7.77 ether;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        uint256 bobGained = bob.balance - bobBefore;
        uint256 protocolHeld = address(protocol).balance;

        assertEq(bobGained + protocolHeld, amount);
    }

    function test_invariant_feeRecipientNeverChanges() public {
        assertEq(protocol.getFeeRecipient(), deployer);

        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(bob);
        assertEq(protocol.getFeeRecipient(), deployer);

        vm.prank(deployer);
        protocol.sweepETH();
        assertEq(protocol.getFeeRecipient(), deployer);
    }

    function test_invariant_protocolNeverHoldsTokensFromRouting() public {
        vm.prank(alice);
        protocol.routeToken(address(token), bob, 10_000e18);

        assertEq(token.balanceOf(address(protocol)), 0);
    }

    // ═══════════════ PAUSE TESTS (8) ═══════════════

    function test_pause_setPaused() public {
        vm.prank(deployer);
        protocol.setPaused(true);
        assertTrue(protocol.isPaused());
    }

    function test_pause_setUnpaused() public {
        vm.startPrank(deployer);
        protocol.setPaused(true);
        protocol.setPaused(false);
        vm.stopPrank();
        assertFalse(protocol.isPaused());
    }

    function test_pause_revert_notDeployer() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.setPaused.selector, true)
        );
        assertFalse(ok);
    }

    function test_pause_routeToken_reverts() public {
        vm.prank(deployer);
        protocol.setPaused(true);

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
    }

    function test_pause_routeETH_reverts() public {
        vm.prank(deployer);
        protocol.setPaused(true);

        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.routeETH.selector, bob)
        );
        assertFalse(ok);
    }

    function test_pause_sweepETH_worksWhenPaused() public {
        // Generate fees first
        vm.prank(alice);
        protocol.routeETH{value: 10 ether}(bob);

        // Pause
        vm.prank(deployer);
        protocol.setPaused(true);

        // Sweep should still work (emergency withdraw)
        uint256 fee = address(protocol).balance;
        uint256 deployerBefore = deployer.balance;
        vm.prank(deployer);
        protocol.sweepETH();

        assertEq(deployer.balance - deployerBefore, fee);
    }

    function test_pause_sweepToken_worksWhenPaused() public {
        token.mint(address(protocol), 1000e18);

        vm.prank(deployer);
        protocol.setPaused(true);

        vm.prank(deployer);
        protocol.sweepToken(address(token));

        assertEq(token.balanceOf(address(protocol)), 0);
    }

    function test_pause_event() public {
        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.SetPaused(true);

        vm.prank(deployer);
        protocol.setPaused(true);
    }

    // ═══════════════ WHITELIST TESTS (10) ═══════════════

    function test_whitelist_enableWhitelist() public {
        vm.prank(deployer);
        protocol.setWhitelistEnabled(true);
        assertTrue(protocol.isWhitelistEnabled());
    }

    function test_whitelist_disableWhitelist() public {
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.setWhitelistEnabled(false);
        vm.stopPrank();
        assertFalse(protocol.isWhitelistEnabled());
    }

    function test_whitelist_addToken() public {
        vm.prank(deployer);
        protocol.whitelistToken(address(token), true);
        assertTrue(protocol.isWhitelisted(address(token)));
    }

    function test_whitelist_removeToken() public {
        vm.startPrank(deployer);
        protocol.whitelistToken(address(token), true);
        protocol.whitelistToken(address(token), false);
        vm.stopPrank();
        assertFalse(protocol.isWhitelisted(address(token)));
    }

    function test_whitelist_routeToken_whitelisted() public {
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        vm.stopPrank();

        vm.prank(alice);
        bool ok = protocol.routeToken(address(token), bob, 1000e18);
        assertTrue(ok);
    }

    function test_whitelist_routeToken_notWhitelisted_reverts() public {
        vm.prank(deployer);
        protocol.setWhitelistEnabled(true);
        // token NOT whitelisted

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
    }

    function test_whitelist_routeETH_unaffected() public {
        // ETH routing should work even with whitelist enabled
        vm.prank(deployer);
        protocol.setWhitelistEnabled(true);

        vm.prank(alice);
        bool ok = protocol.routeETH{value: 1 ether}(bob);
        assertTrue(ok);
    }

    function test_whitelist_revert_notDeployer() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.whitelistToken.selector, address(token), true)
        );
        assertFalse(ok);
    }

    function test_whitelist_revert_zeroAddress() public {
        vm.prank(deployer);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.whitelistToken.selector, address(0), true)
        );
        assertFalse(ok);
    }

    function test_whitelist_event() public {
        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.TokenWhitelistUpdated(address(token), true);

        vm.prank(deployer);
        protocol.whitelistToken(address(token), true);
    }

    // ═══════════════ MAX FEE TESTS (7) ═══════════════

    function test_maxFee_setMaxFee() public {
        vm.prank(deployer);
        protocol.setMaxFee(100);
        assertEq(protocol.getMaxFee(), 100);
    }

    function test_maxFee_revert_notDeployer() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.setMaxFee.selector, 100)
        );
        assertFalse(ok);
    }

    function test_maxFee_capToken() public {
        // Set max fee to 10 tokens
        uint256 maxFee = 10e18;
        vm.prank(deployer);
        protocol.setMaxFee(maxFee);

        // Route 100,000 tokens — normal fee would be 500 tokens, but capped at 10
        uint256 amount = 100_000e18;
        uint256 expectedNet = amount - maxFee;
        uint256 bobBefore = token.balanceOf(bob);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer) - deployerBefore, maxFee);
        assertEq(token.balanceOf(bob) - bobBefore, expectedNet);
    }

    function test_maxFee_capETH() public {
        // Set max fee to 0.01 ETH
        uint256 maxFee = 0.01 ether;
        vm.prank(deployer);
        protocol.setMaxFee(maxFee);

        // Route 100 ETH — normal fee would be 0.5 ETH, but capped at 0.01
        uint256 amount = 100 ether;
        uint256 expectedNet = amount - maxFee;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        protocol.routeETH{value: amount}(bob);

        assertEq(bob.balance - bobBefore, expectedNet);
        assertEq(address(protocol).balance, maxFee);
    }

    function test_maxFee_noCap() public {
        // maxFee = 0 means no cap (default)
        assertEq(protocol.getMaxFee(), 0);

        uint256 amount = 100_000e18;
        uint256 expectedFee = _fee(amount); // 500e18

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer), expectedFee);
    }

    function test_maxFee_belowCap() public {
        // Set cap higher than actual fee — fee should be unchanged
        vm.prank(deployer);
        protocol.setMaxFee(1000e18); // cap at 1000 tokens

        uint256 amount = 10_000e18; // fee = 50e18, well below cap
        uint256 expectedFee = _fee(amount);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer), expectedFee);
    }

    function test_maxFee_event() public {
        vm.expectEmit(true, true, true, true);
        emit IJumpiProtocol.MaxFeeUpdated(42);

        vm.prank(deployer);
        protocol.setMaxFee(42);
    }

    // ═══════════════ REENTRANCY TESTS (2) ═══════════════

    function test_reentrancy_routeETH_reverts() public {
        ReentrantETHAttacker attacker = new ReentrantETHAttacker(protocol);
        vm.deal(address(attacker), 10 ether);

        // The attack should revert because the reentrant call hits the lock
        vm.expectRevert();
        attacker.attack{value: 2 ether}();
    }

    function test_reentrancy_lockReleasedAfterSuccess() public {
        // Normal route should work, then a second route should also work
        // (proving the lock is released after success)
        vm.startPrank(alice);
        protocol.routeETH{value: 1 ether}(bob);
        protocol.routeETH{value: 1 ether}(charlie);
        vm.stopPrank();

        assertEq(address(protocol).balance, _fee(1 ether) * 2);
    }

    // ═══════════════ DELEGATECALL TESTS (2) ═══════════════

    function test_delegatecall_reverts() public {
        DelegateCaller caller_ = new DelegateCaller();
        bytes memory data = abi.encodeWithSelector(IJumpiProtocol.getFeeRecipient.selector);

        (bool success,) = caller_.tryDelegatecall(address(protocol), data);
        assertFalse(success);
    }

    function test_delegatecall_normalCallWorks() public view {
        // Normal call should work fine (proves guard doesn't block regular calls)
        address result = protocol.getFeeRecipient();
        assertEq(result, deployer);
    }

    // ═══════════════ ADMIN ACCESS TESTS (4) ═══════════════

    function test_admin_setWhitelistEnabled_onlyDeployer() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.setWhitelistEnabled.selector, true)
        );
        assertFalse(ok);
    }

    function test_admin_allViewsDefaultCorrectly() public view {
        assertFalse(protocol.isPaused());
        assertFalse(protocol.isWhitelistEnabled());
        assertEq(protocol.getMaxFee(), 0);
        assertFalse(protocol.isWhitelisted(address(token)));
    }

    function test_admin_deployerCanDoEverything() public {
        vm.startPrank(deployer);
        protocol.setPaused(true);
        protocol.setPaused(false);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        protocol.setMaxFee(1000);
        protocol.setWhitelistEnabled(false);
        protocol.setMaxFee(0);
        vm.stopPrank();
    }

    function test_admin_pauseDoesNotAffectViews() public {
        vm.prank(deployer);
        protocol.setPaused(true);

        // View functions should still work
        assertEq(protocol.getFeeRecipient(), deployer);
        assertEq(protocol.getFeeBps(), 50);
        assertTrue(protocol.isPaused());
    }

    // ═══════════════ INTEGRATION / HARDENED CHAOS (6) ═══════════════

    function test_hardened_pauseUnpauseRoute() public {
        // Pause
        vm.prank(deployer);
        protocol.setPaused(true);

        // Route fails
        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);

        // Unpause
        vm.prank(deployer);
        protocol.setPaused(false);

        // Route succeeds
        vm.prank(alice);
        ok = protocol.routeToken(address(token), bob, 1000e18);
        assertTrue(ok);
    }

    function test_hardened_whitelistLifecycle() public {
        // Enable whitelist, add token, route succeeds
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        vm.stopPrank();

        vm.prank(alice);
        protocol.routeToken(address(token), bob, 1000e18);

        // Remove token, route fails
        vm.prank(deployer);
        protocol.whitelistToken(address(token), false);

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
    }

    function test_hardened_maxFeeAndWhitelist() public {
        // Both active at once
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        protocol.setMaxFee(5e18); // cap fee at 5 tokens
        vm.stopPrank();

        uint256 amount = 100_000e18; // normal fee = 500e18, capped to 5e18
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        protocol.routeToken(address(token), bob, amount);

        assertEq(token.balanceOf(deployer), 5e18);
        assertEq(token.balanceOf(bob) - bobBefore, amount - 5e18);
    }

    function test_hardened_pauseSweepUnpauseRoute() public {
        // Route to generate fees
        vm.prank(alice);
        protocol.routeETH{value: 10 ether}(bob);

        // Pause + emergency sweep
        vm.startPrank(deployer);
        protocol.setPaused(true);
        protocol.sweepETH();

        // Unpause + route again
        protocol.setPaused(false);
        vm.stopPrank();

        vm.prank(alice);
        protocol.routeETH{value: 5 ether}(charlie);

        assertEq(address(protocol).balance, _fee(5 ether));
    }

    function test_hardened_fullSecurityStack() public {
        // Enable all safety features
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        protocol.whitelistToken(address(token2), true);
        protocol.setMaxFee(100e18);
        vm.stopPrank();

        // Route both tokens
        vm.startPrank(alice);
        protocol.routeToken(address(token), bob, 50_000e18);
        protocol.routeToken(address(token2), charlie, 50_000e18);
        protocol.routeETH{value: 50 ether}(bob);
        vm.stopPrank();

        // Token fees capped at 100e18 each (normal would be 250e18)
        assertEq(token.balanceOf(deployer), 100e18);
        assertEq(token2.balanceOf(deployer), 100e18);
        // ETH fee: 0.25 ether, capped at 100e18 (100 ETH) — not capped since 0.25 < 100
        assertEq(address(protocol).balance, _fee(50 ether));

        // Protocol never holds tokens (fees go direct to deployer via transferFrom)
        assertEq(token.balanceOf(address(protocol)), 0);
        assertEq(token2.balanceOf(address(protocol)), 0);

        // Sweep ETH only
        vm.prank(deployer);
        protocol.sweepETH();

        assertEq(address(protocol).balance, 0);
    }

    function test_hardened_nonWhitelistedToken2_reverts() public {
        vm.startPrank(deployer);
        protocol.setWhitelistEnabled(true);
        protocol.whitelistToken(address(token), true);
        // token2 NOT whitelisted
        vm.stopPrank();

        vm.prank(alice);
        (bool ok,) = address(protocol).call(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token2), bob, 1000e18)
        );
        assertFalse(ok);
    }

    // ═══════════════ FIX 1: NONPAYABLE ENFORCEMENT (5) ═══════════════

    function test_fix1_routeToken_withETH_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
        assertEq(address(protocol).balance, 0); // no ETH captured
    }

    function test_fix1_routeToken_withETH_ethReturnedOnRevert() public {
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 0.5 ether}(
            abi.encodeWithSelector(IJumpiProtocol.routeToken.selector, address(token), bob, 1000e18)
        );
        assertFalse(ok);
        assertEq(alice.balance, aliceEthBefore); // revert returns ETH to caller
    }

    function test_fix1_sweepETH_withETH_reverts() public {
        vm.prank(alice);
        protocol.routeETH{value: 1 ether}(bob);
        uint256 feeBefore = address(protocol).balance;

        vm.deal(deployer, 0.1 ether);
        vm.prank(deployer);
        (bool ok,) = address(protocol).call{value: 0.1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.sweepETH.selector)
        );
        assertFalse(ok);
        assertEq(address(protocol).balance, feeBefore); // fees intact, nothing swept
    }

    function test_fix1_setPaused_withETH_reverts() public {
        vm.deal(deployer, 0.1 ether);
        vm.prank(deployer);
        (bool ok,) = address(protocol).call{value: 0.1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.setPaused.selector, true)
        );
        assertFalse(ok);
        assertFalse(protocol.isPaused()); // state unchanged
        assertEq(address(protocol).balance, 0);
    }

    function test_fix1_viewFunction_withETH_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 0.01 ether}(
            abi.encodeWithSelector(IJumpiProtocol.getFeeRecipient.selector)
        );
        assertFalse(ok);
        assertEq(address(protocol).balance, 0); // no ETH captured
    }

    // ═══════════════ FIX 2: ZERO-FEE SKIP (2) ═══════════════

    function test_fix2_zeroFee_zeroRevertToken_succeeds() public {
        // ZeroRevertToken reverts if transferFrom is called with amount=0.
        // Before this fix, routing amounts < 200 would call transferFrom(caller, feeRecipient, 0)
        // and revert. Now the second call is skipped entirely.
        ZeroRevertToken zrt = new ZeroRevertToken();
        uint256 amount = 199; // fee = 199 * 50 / 10000 = 0
        zrt.mint(alice, amount);
        vm.prank(alice);
        zrt.approve(address(protocol), type(uint256).max);

        uint256 bobBefore = zrt.balanceOf(bob);
        vm.prank(alice);
        bool ok = protocol.routeToken(address(zrt), bob, amount);
        assertTrue(ok);
        assertEq(zrt.balanceOf(bob) - bobBefore, amount); // bob gets all 199
        assertEq(zrt.balanceOf(deployer), 0);             // deployer gets nothing (fee=0)
    }

    function test_fix2_zeroFee_noDeployerBalance() public {
        // Amount 1: fee = 0, net = 1. Deployer receives nothing.
        token.mint(alice, 1);
        uint256 deployerBefore = token.balanceOf(deployer);

        vm.prank(alice);
        bool ok = protocol.routeToken(address(token), bob, 1);
        assertTrue(ok);
        assertEq(token.balanceOf(deployer), deployerBefore); // no change — second call skipped
    }

    // ═══════════════ ETH REJECTION COVERAGE (1) ═══════════════

    function test_routeETH_rejecting_recipient_reverts() public {
        // routeETH to a contract with no receive/fallback should revert the entire tx.
        // No ETH gets stuck in protocol (claim from README verified here).
        ETHRejecter rejecter = new ETHRejecter();

        vm.prank(alice);
        (bool ok,) = address(protocol).call{value: 1 ether}(
            abi.encodeWithSelector(IJumpiProtocol.routeETH.selector, address(rejecter))
        );
        assertFalse(ok);
        assertEq(address(rejecter).balance, 0);  // nothing sent to rejecter
        assertEq(address(protocol).balance, 0);  // no ETH stuck in protocol
    }
}
