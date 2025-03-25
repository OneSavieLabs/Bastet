// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import './INukeFund.sol';
import '../TraitForgeNft/ITraitForgeNft.sol';
import '../Airdrop/IAirdrop.sol';

contract NukeFund is INukeFund, ReentrancyGuard, Ownable, Pausable {
  uint256 public constant MAX_DENOMINATOR = 100000;

  uint256 private fund;
  ITraitForgeNft public nftContract;
  IAirdrop public airdropContract;
  address payable public devAddress;
  address payable public daoAddress;
  uint256 public taxCut = 10;
  uint256 public defaultNukeFactorIncrease = 250;
  uint256 public maxAllowedClaimDivisor = 2;
  uint256 public nukeFactorMaxParam = MAX_DENOMINATOR / 2;
  uint256 public minimumDaysHeld = 3 days;
  uint256 public ageMultiplier;

  // Constructor now properly passes the initial owner address to the Ownable constructor
  constructor(
    address _traitForgeNft,
    address _airdrop,
    address payable _devAddress,
    address payable _daoAddress
  ) {
    nftContract = ITraitForgeNft(_traitForgeNft);
    airdropContract = IAirdrop(_airdrop);
    devAddress = _devAddress; // Set the developer's address
    daoAddress = _daoAddress;
  }

  // Fallback function to receive ETH and update fund balance
  receive() external payable {
    uint256 devShare = msg.value / taxCut; // Calculate developer's share (10%)
    uint256 remainingFund = msg.value - devShare; // Calculate remaining funds to add to the fund

    fund += remainingFund; // Update the fund balance

    if (!airdropContract.airdropStarted()) {
      (bool success, ) = devAddress.call{ value: devShare }('');
      require(success, 'ETH send failed');
      emit DevShareDistributed(devShare);
    } else if (!airdropContract.daoFundAllowed()) {
      (bool success, ) = payable(owner()).call{ value: devShare }('');
      require(success, 'ETH send failed');
    } else {
      (bool success, ) = daoAddress.call{ value: devShare }('');
      require(success, 'ETH send failed');
      emit DevShareDistributed(devShare);
    }

    emit FundReceived(msg.sender, msg.value); // Log the received funds
    emit FundBalanceUpdated(fund); // Update the fund balance
  }

  function setTaxCut(uint256 _taxCut) external onlyOwner {
    taxCut = _taxCut;
  }

  function setMinimumDaysHeld(uint256 value) external onlyOwner {
    minimumDaysHeld = value;
  }

  function setDefaultNukeFactorIncrease(uint256 value) external onlyOwner {
    defaultNukeFactorIncrease = value;
  }

  function setMaxAllowedClaimDivisor(uint256 value) external onlyOwner {
    maxAllowedClaimDivisor = value;
  }

  function setNukeFactorMaxParam(uint256 value) external onlyOwner {
    nukeFactorMaxParam = value;
  }

  // Allow the owner to update the reference to the ERC721 contract
  function setTraitForgeNftContract(address _traitForgeNft) external onlyOwner {
    nftContract = ITraitForgeNft(_traitForgeNft);
    emit TraitForgeNftAddressUpdated(_traitForgeNft); // Emit an event when the address is updated.
  }

  function setAirdropContract(address _airdrop) external onlyOwner {
    airdropContract = IAirdrop(_airdrop);
    emit AirdropAddressUpdated(_airdrop); // Emit an event when the address is updated.
  }

  function setDevAddress(address payable account) external onlyOwner {
    devAddress = account;
    emit DevAddressUpdated(account);
  }

  function setDaoAddress(address payable account) external onlyOwner {
    daoAddress = account;
    emit DaoAddressUpdated(account);
  }

  // View function to see the current balance of the fund
  function getFundBalance() public view returns (uint256) {
    return fund;
  }

  function setAgeMultplier(uint256 _ageMultiplier) external onlyOwner {
    ageMultiplier = _ageMultiplier;
  }

  function getAgeMultiplier() public view returns (uint256) {
    return ageMultiplier;
  }

  // Calculate the age of a token based on its creation timestamp and current time
  function calculateAge(uint256 tokenId) public view returns (uint256) {
    require(nftContract.ownerOf(tokenId) != address(0), 'Token does not exist');

    uint256 daysOld = (block.timestamp -
      nftContract.getTokenCreationTimestamp(tokenId)) /
      60 /
      60 /
      24;
    uint256 perfomanceFactor = nftContract.getTokenEntropy(tokenId) % 10;

    uint256 age = (daysOld *
      perfomanceFactor *
      MAX_DENOMINATOR *
      ageMultiplier) / 365; // add 5 digits for decimals
    return age;
  }

  // Calculate the nuke factor of a token, which affects the claimable amount from the fund
  function calculateNukeFactor(uint256 tokenId) public view returns (uint256) {
    require(
      nftContract.ownerOf(tokenId) != address(0),
      'ERC721: operator query for nonexistent token'
    );

    uint256 entropy = nftContract.getTokenEntropy(tokenId);
    uint256 adjustedAge = calculateAge(tokenId);

    uint256 initialNukeFactor = entropy / 40; // calcualte initalNukeFactor based on entropy, 5 digits

    uint256 finalNukeFactor = ((adjustedAge * defaultNukeFactorIncrease) /
      MAX_DENOMINATOR) + initialNukeFactor;

    return finalNukeFactor;
  }

  function nuke(uint256 tokenId) public whenNotPaused nonReentrant {
    require(
      nftContract.isApprovedOrOwner(msg.sender, tokenId),
      'ERC721: caller is not token owner or approved'
    );
    require(
      nftContract.getApproved(tokenId) == address(this) ||
        nftContract.isApprovedForAll(msg.sender, address(this)),
      'Contract must be approved to transfer the NFT.'
    );
    require(canTokenBeNuked(tokenId), 'Token is not mature yet');

    uint256 finalNukeFactor = calculateNukeFactor(tokenId); // finalNukeFactor has 5 digits
    uint256 potentialClaimAmount = (fund * finalNukeFactor) / MAX_DENOMINATOR; // Calculate the potential claim amount based on the finalNukeFactor
    uint256 maxAllowedClaimAmount = fund / maxAllowedClaimDivisor; // Define a maximum allowed claim amount as 50% of the current fund size

    // Directly assign the value to claimAmount based on the condition, removing the redeclaration
    uint256 claimAmount = finalNukeFactor > nukeFactorMaxParam
      ? maxAllowedClaimAmount
      : potentialClaimAmount;

    fund -= claimAmount; // Deduct the claim amount from the fund

    nftContract.burn(tokenId); // Burn the token
    (bool success, ) = payable(msg.sender).call{ value: claimAmount }('');
    require(success, 'Failed to send Ether');

    emit Nuked(msg.sender, tokenId, claimAmount); // Emit the event with the actual claim amount
    emit FundBalanceUpdated(fund); // Update the fund balance
  }

  function canTokenBeNuked(uint256 tokenId) public view returns (bool) {
    // Ensure the token exists
    require(
      nftContract.ownerOf(tokenId) != address(0),
      'ERC721: operator query for nonexistent token'
    );
    uint256 tokenAgeInSeconds = block.timestamp -
      nftContract.getTokenLastTransferredTimestamp(tokenId);
    // Assuming tokenAgeInSeconds is the age of the token since it's holding the nft, check if it's over minimum days held
    return tokenAgeInSeconds >= minimumDaysHeld;
  }
}