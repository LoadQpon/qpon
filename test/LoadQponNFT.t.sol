// SPDX-License-Identifier: UNLICENSED
pragma solidity ^1.1.2;

import "spark-std/Test.sol";
import "core-openzeppelin-contracts/src/proxy/ERC1967/ERC1967Proxy.sol";
import "core-openzeppelin-contracts/src/token/CRC721/ICRC721Receiver.sol";
import "core-openzeppelin-contracts-upgradeable/src/utils/ChecksumUpgradeable.sol";
import "../src/LoadQponNFT.sol";

contract RejectingVoucherReceiver is ICRC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        revert("receiver rejected");
    }
}

contract NonVoucherReceiver {}

contract ReentrantOpeningReceiver is ICRC721Receiver {
    LoadQponNFT private immutable _qpon;

    bool public attempted;
    bool public blocked;

    constructor(LoadQponNFT qpon_) {
        _qpon = qpon_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        attempted = true;
        try _qpon.openVoucher(tokenId, bytes32("reentrant-redemption"), bytes32("reentrant-beneficiary")) {
            blocked = false;
        } catch {
            blocked = true;
        }

        return ICRC721Receiver.onERC721Received.selector;
    }
}

contract LoadQponNFTV2Mock is LoadQponNFT {
    function implementationVersion() external pure returns (uint256) {
        return 2;
    }
}

contract LoadQponNFTTest is Test {
    event VoucherMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        bytes32 indexed mintKey,
        bytes32 currencyId,
        uint256 valueMinor
    );
    event VoucherOpened(
        uint256 indexed tokenId,
        bytes32 indexed redemptionKey,
        address indexed owner,
        bytes32 beneficiaryKey,
        bytes32 currencyId,
        uint256 valueMinor
    );

    bytes32 private constant CNY = bytes32("CNY");
    bytes32 private constant EUR = bytes32("EUR");
    uint256 private constant MAX_VOUCHER_VALUE = 100_000_000;
    uint256 private constant FACE_VALUE = 50_000;

    LoadQponNFT private _implementation;
    LoadQponNFT private _qpon;

    address private _owner;
    address private _minter;
    address private _alice;
    address private _bob;
    address private _operator;
    address private _outsider;

    function setUp() public {
        _owner = makeAddr("owner");
        _minter = makeAddr("minter");
        _alice = makeAddr("alice");
        _bob = makeAddr("bob");
        _operator = makeAddr("operator");
        _outsider = makeAddr("outsider");

        _implementation = new LoadQponNFT();
        bytes memory initData = abi.encodeWithSelector(LoadQponNFT.initialize.selector, "Load Qpon", "QPON", _owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(_implementation), initData);
        _qpon = LoadQponNFT(address(proxy));

        vm.startPrank(_owner);
        _qpon.setMinter(_minter, true);
        _qpon.setCurrency(CNY, MAX_VOUCHER_VALUE, true);
        vm.stopPrank();
    }

    function testInitialization() public {
        assertEq(_qpon.name(), "Load Qpon");
        assertEq(_qpon.symbol(), "QPON");
        assertEq(_qpon.owner(), _owner);
        assertEq(_qpon.AMOUNT_DECIMALS(), 2);
        assertEq(_qpon.nextTokenId(), 1);
        assertTrue(_qpon.isMinter(_minter));
    }

    function testProxyCannotBeInitializedTwice() public {
        vm.expectRevert();
        _qpon.initialize("Other", "OTHER", _outsider);
    }

    function testImplementationIsLocked() public {
        vm.expectRevert();
        _implementation.initialize("Other", "OTHER", _outsider);
    }

    function testOnlyOwnerCanManageMinters() public {
        vm.prank(_outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _qpon.setMinter(_outsider, true);

        vm.prank(_owner);
        _qpon.setMinter(_outsider, true);
        assertTrue(_qpon.isMinter(_outsider));

        vm.prank(_owner);
        _qpon.setMinter(_outsider, false);
        assertFalse(_qpon.isMinter(_outsider));
    }

    function testCannotSetZeroMinter() public {
        vm.prank(_owner);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, address(0)));
        _qpon.setMinter(address(0), true);

        address checksumZero = ChecksumUpgradeable.zeroAddress();
        vm.prank(_owner);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, checksumZero));
        _qpon.setMinter(checksumZero, true);
    }

    function testOwnerConfiguresCurrencyWithoutResettingAccounting() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("mint-currency"));

        vm.prank(_owner);
        _qpon.setCurrency(CNY, MAX_VOUCHER_VALUE * 2, false);

        LoadQponNFT.CurrencyConfig memory currency = _qpon.getCurrency(CNY);
        assertTrue(currency.exists);
        assertFalse(currency.mintEnabled);
        assertEq(currency.maxVoucherValue, MAX_VOUCHER_VALUE * 2);
        assertEq(currency.mintedValue, FACE_VALUE);
        assertEq(currency.redeemedValue, 0);
        assertEq(currency.outstandingValue, FACE_VALUE);
        assertEq(_qpon.ownerOf(tokenId), _alice);
    }

    function testCurrencyConfigurationRejectsInvalidValues() public {
        vm.startPrank(_owner);

        vm.expectRevert(LoadQponNFT.InvalidCurrencyId.selector);
        _qpon.setCurrency(bytes32(0), MAX_VOUCHER_VALUE, true);

        vm.expectRevert(LoadQponNFT.InvalidMaximumValue.selector);
        _qpon.setCurrency(EUR, 0, true);

        vm.stopPrank();
    }

    function testAuthorizedMinterCreatesVoucherAndAuditLookups() public {
        bytes32 mintKey = bytes32("mint-success");

        vm.expectEmit(true, true, true, true, address(_qpon));
        emit VoucherMinted(1, _alice, mintKey, CNY, FACE_VALUE);

        vm.prank(_minter);
        uint256 tokenId = _qpon.mintVoucher(_alice, CNY, FACE_VALUE, mintKey);

        assertEq(tokenId, 1);
        assertEq(_qpon.ownerOf(tokenId), _alice);
        assertEq(_qpon.balanceOf(_alice), 1);
        assertEq(_qpon.totalSupply(), 1);
        assertEq(_qpon.tokenOfOwnerByIndex(_alice, 0), tokenId);
        assertEq(_qpon.tokenByIndex(0), tokenId);
        assertEq(_qpon.nextTokenId(), 2);

        LoadQponNFT.Voucher memory voucher = _qpon.getVoucher(tokenId);
        assertTrue(voucher.issued);
        assertFalse(voucher.redeemed);
        assertEq(voucher.currencyId, CNY);
        assertEq(voucher.valueMinor, FACE_VALUE);
        assertEq(voucher.mintKey, mintKey);
        assertEq(voucher.redemptionKey, bytes32(0));

        (bool exists, uint256 lookedUpTokenId) = _qpon.getMint(mintKey);
        assertTrue(exists);
        assertEq(lookedUpTokenId, tokenId);

        LoadQponNFT.CurrencyConfig memory currency = _qpon.getCurrency(CNY);
        assertEq(currency.mintedValue, FACE_VALUE);
        assertEq(currency.redeemedValue, 0);
        assertEq(currency.outstandingValue, FACE_VALUE);
    }

    function testUnauthorizedAccountCannotMint() public {
        vm.prank(_outsider);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.NotMinter.selector, _outsider));
        _qpon.mintVoucher(_alice, CNY, FACE_VALUE, bytes32("unauthorized"));
    }

    function testMintRejectsInvalidInputs() public {
        vm.startPrank(_minter);

        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, address(0)));
        _qpon.mintVoucher(address(0), CNY, FACE_VALUE, bytes32("zero-recipient"));

        address malformedRecipient = address(1);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, malformedRecipient));
        _qpon.mintVoucher(malformedRecipient, CNY, FACE_VALUE, bytes32("malformed-recipient"));

        vm.expectRevert(LoadQponNFT.InvalidMintKey.selector);
        _qpon.mintVoucher(_alice, CNY, FACE_VALUE, bytes32(0));

        vm.expectRevert(LoadQponNFT.InvalidVoucherValue.selector);
        _qpon.mintVoucher(_alice, CNY, 0, bytes32("zero-value"));

        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.CurrencyNotConfigured.selector, EUR));
        _qpon.mintVoucher(_alice, EUR, FACE_VALUE, bytes32("unknown-currency"));

        vm.expectRevert(
            abi.encodeWithSelector(
                LoadQponNFT.VoucherValueExceedsMaximum.selector, MAX_VOUCHER_VALUE + 1, MAX_VOUCHER_VALUE
            )
        );
        _qpon.mintVoucher(_alice, CNY, MAX_VOUCHER_VALUE + 1, bytes32("oversize"));

        vm.stopPrank();
    }

    function testMintRejectsDisabledCurrency() public {
        vm.prank(_owner);
        _qpon.setCurrency(CNY, MAX_VOUCHER_VALUE, false);

        vm.prank(_minter);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.CurrencyMintingDisabled.selector, CNY));
        _qpon.mintVoucher(_alice, CNY, FACE_VALUE, bytes32("disabled"));
    }

    function testDuplicateMintKeyRejectedBeforeAndAfterBurn() public {
        bytes32 mintKey = bytes32("permanent-mint-key");
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, mintKey);

        vm.prank(_minter);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.MintKeyAlreadyUsed.selector, mintKey, tokenId));
        _qpon.mintVoucher(_bob, CNY, FACE_VALUE, mintKey);

        _openAs(_alice, tokenId, bytes32("redeem-first"), bytes32("beneficiary-first"));

        vm.prank(_owner);
        _qpon.setCurrency(CNY, MAX_VOUCHER_VALUE, false);

        vm.prank(_minter);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.MintKeyAlreadyUsed.selector, mintKey, tokenId));
        _qpon.mintVoucher(_bob, CNY, FACE_VALUE, mintKey);
    }

    function testSafeMintRevertsAndRollsBackForRejectingReceiver() public {
        RejectingVoucherReceiver receiver = new RejectingVoucherReceiver();
        bytes32 mintKey = bytes32("rejecting-receiver");

        vm.prank(_minter);
        vm.expectRevert(bytes("receiver rejected"));
        _qpon.mintVoucher(address(receiver), CNY, FACE_VALUE, mintKey);

        (bool exists, uint256 tokenId) = _qpon.getMint(mintKey);
        assertFalse(exists);
        assertEq(tokenId, 0);
        assertEq(_qpon.totalSupply(), 0);
        assertEq(_qpon.nextTokenId(), 1);

        LoadQponNFT.CurrencyConfig memory currency = _qpon.getCurrency(CNY);
        assertEq(currency.mintedValue, 0);
        assertEq(currency.outstandingValue, 0);
    }

    function testSafeMintRejectsContractWithoutReceiver() public {
        NonVoucherReceiver receiver = new NonVoucherReceiver();

        vm.prank(_minter);
        vm.expectRevert(bytes("CRC721: transfer to non CRC721Receiver implementer"));
        _qpon.mintVoucher(address(receiver), CNY, FACE_VALUE, bytes32("non-receiver"));
    }

    function testReceiverCannotReenterOpeningDuringMint() public {
        ReentrantOpeningReceiver receiver = new ReentrantOpeningReceiver(_qpon);
        uint256 tokenId = _mintTo(address(receiver), FACE_VALUE, bytes32("reentrant-mint"));

        assertTrue(receiver.attempted());
        assertTrue(receiver.blocked());
        assertEq(_qpon.ownerOf(tokenId), address(receiver));

        LoadQponNFT.Voucher memory voucher = _qpon.getVoucher(tokenId);
        assertFalse(voucher.redeemed);
    }

    function testTransferUpdatesOwnerEnumeration() public {
        uint256 firstTokenId = _mintTo(_alice, FACE_VALUE, bytes32("enumerable-one"));
        uint256 secondTokenId = _mintTo(_alice, FACE_VALUE, bytes32("enumerable-two"));

        vm.prank(_alice);
        _qpon.transferFrom(_alice, _bob, firstTokenId);

        assertEq(_qpon.balanceOf(_alice), 1);
        assertEq(_qpon.balanceOf(_bob), 1);
        assertEq(_qpon.tokenOfOwnerByIndex(_alice, 0), secondTokenId);
        assertEq(_qpon.tokenOfOwnerByIndex(_bob, 0), firstTokenId);
        assertEq(_qpon.totalSupply(), 2);
    }

    function testTransferRejectsMalformedCoreAddress() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("malformed-transfer"));
        address malformedRecipient = address(1);

        vm.prank(_alice);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, malformedRecipient));
        _qpon.transferFrom(_alice, malformedRecipient, tokenId);

        assertEq(_qpon.ownerOf(tokenId), _alice);
    }

    function testApprovedOperatorCanTransferButCannotOpen() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("approved-operator"));

        vm.prank(_alice);
        _qpon.approve(_operator, tokenId);

        vm.prank(_operator);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.NotVoucherOwner.selector, _operator, _alice));
        _qpon.openVoucher(tokenId, bytes32("operator-redemption"), bytes32("operator-beneficiary"));

        vm.prank(_operator);
        _qpon.transferFrom(_alice, _bob, tokenId);
        assertEq(_qpon.ownerOf(tokenId), _bob);
    }

    function testOwnerOpensFullVoucherAndAuditSurvivesBurn() public {
        bytes32 mintKey = bytes32("open-success");
        bytes32 redemptionKey = bytes32("redemption-success");
        bytes32 beneficiaryKey = bytes32("beneficiary-success");
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, mintKey);

        vm.expectEmit(true, true, true, true, address(_qpon));
        emit VoucherOpened(tokenId, redemptionKey, _alice, beneficiaryKey, CNY, FACE_VALUE);

        vm.prank(_alice);
        _qpon.openVoucher(tokenId, redemptionKey, beneficiaryKey);

        assertEq(_qpon.totalSupply(), 0);
        assertEq(_qpon.balanceOf(_alice), 0);
        vm.expectRevert(bytes("CRC721: invalid token ID"));
        _qpon.ownerOf(tokenId);

        LoadQponNFT.Voucher memory voucher = _qpon.getVoucher(tokenId);
        assertTrue(voucher.issued);
        assertTrue(voucher.redeemed);
        assertEq(voucher.currencyId, CNY);
        assertEq(voucher.valueMinor, FACE_VALUE);
        assertEq(voucher.mintKey, mintKey);
        assertEq(voucher.redemptionKey, redemptionKey);

        LoadQponNFT.Redemption memory redemption = _qpon.getRedemption(redemptionKey);
        assertTrue(redemption.exists);
        assertEq(redemption.tokenId, tokenId);
        assertEq(redemption.owner, _alice);
        assertEq(redemption.beneficiaryKey, beneficiaryKey);
        assertEq(redemption.currencyId, CNY);
        assertEq(redemption.valueMinor, FACE_VALUE);

        (bool mintExists, uint256 mintTokenId) = _qpon.getMint(mintKey);
        assertTrue(mintExists);
        assertEq(mintTokenId, tokenId);

        LoadQponNFT.CurrencyConfig memory currency = _qpon.getCurrency(CNY);
        assertEq(currency.mintedValue, FACE_VALUE);
        assertEq(currency.redeemedValue, FACE_VALUE);
        assertEq(currency.outstandingValue, 0);
    }

    function testOpeningRejectsInvalidKeysAndWrongOwner() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("invalid-opening"));

        vm.startPrank(_alice);

        vm.expectRevert(LoadQponNFT.InvalidRedemptionKey.selector);
        _qpon.openVoucher(tokenId, bytes32(0), bytes32("beneficiary"));

        vm.expectRevert(LoadQponNFT.InvalidBeneficiaryKey.selector);
        _qpon.openVoucher(tokenId, bytes32("redemption"), bytes32(0));

        vm.stopPrank();

        vm.prank(_outsider);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.NotVoucherOwner.selector, _outsider, _alice));
        _qpon.openVoucher(tokenId, bytes32("redemption"), bytes32("beneficiary"));
    }

    function testOpeningRejectsUnknownAndAlreadyRedeemedVoucher() public {
        vm.prank(_alice);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.VoucherNotFound.selector, 999));
        _qpon.openVoucher(999, bytes32("unknown-redemption"), bytes32("unknown-beneficiary"));

        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("opened-once"));
        _openAs(_alice, tokenId, bytes32("opened-once-redemption"), bytes32("opened-once-beneficiary"));

        vm.prank(_alice);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.VoucherAlreadyRedeemed.selector, tokenId));
        _qpon.openVoucher(tokenId, bytes32("opened-twice"), bytes32("opened-twice-beneficiary"));
    }

    function testRedemptionKeyCannotBeReusedAcrossVouchers() public {
        bytes32 redemptionKey = bytes32("single-redemption-key");
        uint256 firstTokenId = _mintTo(_alice, FACE_VALUE, bytes32("mint-first"));
        uint256 secondTokenId = _mintTo(_bob, FACE_VALUE, bytes32("mint-second"));

        _openAs(_alice, firstTokenId, redemptionKey, bytes32("beneficiary-first"));

        vm.prank(_bob);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.RedemptionKeyAlreadyUsed.selector, redemptionKey));
        _qpon.openVoucher(secondTokenId, redemptionKey, bytes32("beneficiary-second"));

        assertEq(_qpon.ownerOf(secondTokenId), _bob);
    }

    function testPauseBlocksMintTransferAndOpening() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("pause-existing"));

        vm.prank(_owner);
        _qpon.pause();
        assertTrue(_qpon.paused());

        vm.prank(_minter);
        vm.expectRevert(bytes("Pausable: paused"));
        _qpon.mintVoucher(_bob, CNY, FACE_VALUE, bytes32("pause-mint"));

        vm.prank(_alice);
        vm.expectRevert(bytes("Pausable: paused"));
        _qpon.transferFrom(_alice, _bob, tokenId);

        vm.prank(_alice);
        vm.expectRevert(bytes("Pausable: paused"));
        _qpon.openVoucher(tokenId, bytes32("pause-open"), bytes32("pause-beneficiary"));

        vm.prank(_owner);
        _qpon.unpause();

        vm.prank(_alice);
        _qpon.transferFrom(_alice, _bob, tokenId);
        assertEq(_qpon.ownerOf(tokenId), _bob);
    }

    function testOnlyOwnerCanPauseAndUnpause() public {
        vm.prank(_outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _qpon.pause();

        vm.prank(_owner);
        _qpon.pause();

        vm.prank(_outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _qpon.unpause();
    }

    function testOwnerCannotRenounceOwnership() public {
        vm.prank(_owner);
        vm.expectRevert(LoadQponNFT.OwnershipRenunciationDisabled.selector);
        _qpon.renounceOwnership();
    }

    function testOwnershipTransferRequiresValidCoreAddress() public {
        address malformedOwner = address(1);

        vm.prank(_owner);
        vm.expectRevert(abi.encodeWithSelector(LoadQponNFT.InvalidAddress.selector, malformedOwner));
        _qpon.transferOwnership(malformedOwner);

        vm.prank(_owner);
        _qpon.transferOwnership(_bob);
        assertEq(_qpon.owner(), _bob);
    }

    function testBaseURIAndMetadata() public {
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, bytes32("metadata"));
        assertEq(_qpon.tokenURI(tokenId), "");

        vm.prank(_owner);
        _qpon.setBaseURI("https://metadata.load.qpon/vouchers/");

        assertEq(_qpon.tokenURI(tokenId), "https://metadata.load.qpon/vouchers/1");
    }

    function testOnlyOwnerCanUpgradeAndStateIsPreserved() public {
        bytes32 mintKey = bytes32("upgrade-state");
        uint256 tokenId = _mintTo(_alice, FACE_VALUE, mintKey);
        LoadQponNFTV2Mock nextImplementation = new LoadQponNFTV2Mock();

        vm.prank(_outsider);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _qpon.upgradeTo(address(nextImplementation));

        vm.prank(_owner);
        _qpon.upgradeTo(address(nextImplementation));

        LoadQponNFTV2Mock upgraded = LoadQponNFTV2Mock(address(_qpon));
        assertEq(upgraded.implementationVersion(), 2);
        assertEq(upgraded.ownerOf(tokenId), _alice);
        assertEq(upgraded.owner(), _owner);
        assertTrue(upgraded.isMinter(_minter));

        LoadQponNFT.Voucher memory voucher = upgraded.getVoucher(tokenId);
        assertEq(voucher.mintKey, mintKey);
        assertEq(voucher.valueMinor, FACE_VALUE);
    }

    function testFuzzAccountingConservation(uint128 firstRaw, uint128 secondRaw) public {
        uint256 firstValue = bound(uint256(firstRaw), 1, MAX_VOUCHER_VALUE);
        uint256 secondValue = bound(uint256(secondRaw), 1, MAX_VOUCHER_VALUE);

        uint256 firstTokenId = _mintTo(_alice, firstValue, bytes32(uint256(keccak256("fuzz-first"))));
        _mintTo(_bob, secondValue, bytes32(uint256(keccak256("fuzz-second"))));

        _openAs(_alice, firstTokenId, bytes32("fuzz-redemption"), bytes32("fuzz-beneficiary"));

        LoadQponNFT.CurrencyConfig memory currency = _qpon.getCurrency(CNY);
        assertEq(currency.mintedValue, firstValue + secondValue);
        assertEq(currency.redeemedValue, firstValue);
        assertEq(currency.outstandingValue, secondValue);
        assertEq(currency.mintedValue, currency.redeemedValue + currency.outstandingValue);
    }

    function _mintTo(address recipient, uint256 valueMinor, bytes32 mintKey) private returns (uint256 tokenId) {
        vm.prank(_minter);
        tokenId = _qpon.mintVoucher(recipient, CNY, valueMinor, mintKey);
    }

    function _openAs(address account, uint256 tokenId, bytes32 redemptionKey, bytes32 beneficiaryKey) private {
        vm.prank(account);
        _qpon.openVoucher(tokenId, redemptionKey, beneficiaryKey);
    }
}
