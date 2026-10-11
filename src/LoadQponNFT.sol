// SPDX-License-Identifier: MIT
pragma solidity ^1.1.2;

import "core-openzeppelin-contracts-upgradeable/src/access/OwnableUpgradeable.sol";
import "core-openzeppelin-contracts-upgradeable/src/proxy/utils/UUPSUpgradeable.sol";
import "core-openzeppelin-contracts-upgradeable/src/security/PausableUpgradeable.sol";
import "core-openzeppelin-contracts-upgradeable/src/security/ReentrancyGuardUpgradeable.sol";
import "core-openzeppelin-contracts-upgradeable/src/token/CRC721/extensions/CRC721EnumerableUpgradeable.sol";
import "core-openzeppelin-contracts-upgradeable/src/utils/ChecksumUpgradeable.sol";

/**
 * @title LoadQponNFT
 * @notice A transferable, full-redemption-only NFT voucher for Core Blockchain.
 * @dev Monetary amounts use two decimal places and do not represent on-chain funds.
 *      Opening a voucher records its complete value as redeemed and burns the NFT.
 */
contract LoadQponNFT is
    CRC721EnumerableUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    uint8 public constant AMOUNT_DECIMALS = 2;

    struct Voucher {
        bool issued;
        bool redeemed;
        bytes32 currencyId;
        uint256 valueMinor;
        bytes32 mintKey;
        bytes32 redemptionKey;
    }

    struct Redemption {
        bool exists;
        uint256 tokenId;
        address owner;
        bytes32 beneficiaryKey;
        bytes32 currencyId;
        uint256 valueMinor;
    }

    struct CurrencyConfig {
        bool exists;
        bool mintEnabled;
        uint256 maxVoucherValue;
        uint256 mintedValue;
        uint256 redeemedValue;
        uint256 outstandingValue;
    }

    error InvalidAddress(address account);
    error InvalidCurrencyId();
    error InvalidMaximumValue();
    error InvalidVoucherValue();
    error InvalidMintKey();
    error InvalidRedemptionKey();
    error InvalidBeneficiaryKey();
    error NotMinter(address account);
    error CurrencyNotConfigured(bytes32 currencyId);
    error CurrencyMintingDisabled(bytes32 currencyId);
    error VoucherValueExceedsMaximum(uint256 valueMinor, uint256 maximum);
    error MintKeyAlreadyUsed(bytes32 mintKey, uint256 tokenId);
    error RedemptionKeyAlreadyUsed(bytes32 redemptionKey);
    error VoucherNotFound(uint256 tokenId);
    error VoucherAlreadyRedeemed(uint256 tokenId);
    error NotVoucherOwner(address caller, address owner);
    error OwnershipRenunciationDisabled();

    event MinterUpdated(address indexed account, bool enabled);
    event CurrencyUpdated(bytes32 indexed currencyId, uint256 maxVoucherValue, bool mintEnabled);
    event BaseURIUpdated(string newBaseURI);
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

    uint256 private _nextTokenId;
    string private _baseTokenURI;

    mapping(address => bool) private _minters;
    mapping(bytes32 => CurrencyConfig) private _currencies;
    mapping(uint256 => Voucher) private _vouchers;
    mapping(bytes32 => uint256) private _tokenByMintKey;
    mapping(bytes32 => Redemption) private _redemptions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name_, string memory symbol_, address initialOwner_) external initializer {
        if (_isInvalidCoreAddress(initialOwner_)) revert InvalidAddress(initialOwner_);

        __CRC721_init(name_, symbol_);
        __CRC721Enumerable_init();
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (initialOwner_ != _msgSender()) {
            _transferOwnership(initialOwner_);
        }

        _nextTokenId = 1;
    }

    modifier onlyMinter() {
        if (!_minters[_msgSender()]) revert NotMinter(_msgSender());
        _;
    }

    function mintVoucher(address recipient, bytes32 currencyId, uint256 valueMinor, bytes32 mintKey)
        external
        onlyMinter
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        if (_isInvalidCoreAddress(recipient)) revert InvalidAddress(recipient);
        if (mintKey == bytes32(0)) revert InvalidMintKey();

        uint256 existingTokenId = _tokenByMintKey[mintKey];
        if (existingTokenId != 0) revert MintKeyAlreadyUsed(mintKey, existingTokenId);

        if (valueMinor == 0) revert InvalidVoucherValue();

        CurrencyConfig storage currency = _currencies[currencyId];
        if (!currency.exists) revert CurrencyNotConfigured(currencyId);
        if (!currency.mintEnabled) revert CurrencyMintingDisabled(currencyId);
        if (valueMinor > currency.maxVoucherValue) {
            revert VoucherValueExceedsMaximum(valueMinor, currency.maxVoucherValue);
        }

        tokenId = _nextTokenId++;
        _vouchers[tokenId] = Voucher({
            issued: true,
            redeemed: false,
            currencyId: currencyId,
            valueMinor: valueMinor,
            mintKey: mintKey,
            redemptionKey: bytes32(0)
        });
        _tokenByMintKey[mintKey] = tokenId;

        currency.mintedValue += valueMinor;
        currency.outstandingValue += valueMinor;

        _safeMint(recipient, tokenId);

        emit VoucherMinted(tokenId, recipient, mintKey, currencyId, valueMinor);
    }

    function openVoucher(uint256 tokenId, bytes32 redemptionKey, bytes32 beneficiaryKey)
        external
        whenNotPaused
        nonReentrant
    {
        if (redemptionKey == bytes32(0)) revert InvalidRedemptionKey();
        if (beneficiaryKey == bytes32(0)) revert InvalidBeneficiaryKey();

        Voucher storage voucher = _vouchers[tokenId];
        if (!voucher.issued) revert VoucherNotFound(tokenId);
        if (voucher.redeemed) revert VoucherAlreadyRedeemed(tokenId);

        address voucherOwner = ownerOf(tokenId);
        if (_msgSender() != voucherOwner) revert NotVoucherOwner(_msgSender(), voucherOwner);
        if (_redemptions[redemptionKey].exists) revert RedemptionKeyAlreadyUsed(redemptionKey);

        voucher.redeemed = true;
        voucher.redemptionKey = redemptionKey;

        _redemptions[redemptionKey] = Redemption({
            exists: true,
            tokenId: tokenId,
            owner: voucherOwner,
            beneficiaryKey: beneficiaryKey,
            currencyId: voucher.currencyId,
            valueMinor: voucher.valueMinor
        });

        CurrencyConfig storage currency = _currencies[voucher.currencyId];
        currency.redeemedValue += voucher.valueMinor;
        currency.outstandingValue -= voucher.valueMinor;

        _burn(tokenId);

        emit VoucherOpened(tokenId, redemptionKey, voucherOwner, beneficiaryKey, voucher.currencyId, voucher.valueMinor);
    }

    function setMinter(address account, bool enabled) external onlyOwner {
        if (_isInvalidCoreAddress(account)) revert InvalidAddress(account);
        _minters[account] = enabled;
        emit MinterUpdated(account, enabled);
    }

    function setCurrency(bytes32 currencyId, uint256 maxVoucherValue, bool mintEnabled) external onlyOwner {
        if (currencyId == bytes32(0)) revert InvalidCurrencyId();
        if (maxVoucherValue == 0) revert InvalidMaximumValue();

        CurrencyConfig storage currency = _currencies[currencyId];
        currency.exists = true;
        currency.mintEnabled = mintEnabled;
        currency.maxVoucherValue = maxVoucherValue;

        emit CurrencyUpdated(currencyId, maxVoucherValue, mintEnabled);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public virtual override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        if (_isInvalidCoreAddress(newOwner)) revert InvalidAddress(newOwner);
        _transferOwnership(newOwner);
    }

    function isMinter(address account) external view returns (bool) {
        return _minters[account];
    }

    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }

    function getCurrency(bytes32 currencyId) external view returns (CurrencyConfig memory) {
        return _currencies[currencyId];
    }

    function getVoucher(uint256 tokenId) external view returns (Voucher memory) {
        return _vouchers[tokenId];
    }

    function getMint(bytes32 mintKey) external view returns (bool exists, uint256 tokenId) {
        tokenId = _tokenByMintKey[mintKey];
        exists = tokenId != 0;
    }

    function getRedemption(bytes32 redemptionKey) external view returns (Redemption memory) {
        return _redemptions[redemptionKey];
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        virtual
        override(CRC721EnumerableUpgradeable)
        whenNotPaused
    {
        if (to != address(0) && _isInvalidCoreAddress(to)) revert InvalidAddress(to);
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    function _isInvalidCoreAddress(address account) private view returns (bool) {
        return account == address(0) || account == ChecksumUpgradeable.zeroAddress()
            || !ChecksumUpgradeable.isValid(account);
    }

    uint256[40] private __gap;
}
