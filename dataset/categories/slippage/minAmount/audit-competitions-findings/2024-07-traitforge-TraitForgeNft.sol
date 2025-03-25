// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';
import './ITraitForgeNft.sol';
import '../EntityForging/IEntityForging.sol';
import '../EntropyGenerator/IEntropyGenerator.sol';
import '../Airdrop/IAirdrop.sol';

contract TraitForgeNft is
  ITraitForgeNft,
  ERC721Enumerable,
  ReentrancyGuard,
  Ownable,
  Pausable
{
  // Constants for token generation and pricing
  uint256 public maxTokensPerGen = 10000;
  uint256 public startPrice = 0.005 ether;
  uint256 public priceIncrement = 0.0000245 ether;
  uint256 public priceIncrementByGen = 0.000005 ether;

  IEntityForging public entityForgingContract;
  IEntropyGenerator public entropyGenerator;
  IAirdrop public airdropContract;
  address public nukeFundAddress;

  // Variables for managing generations and token IDs
  uint256 public currentGeneration = 1;
  /// @dev generation limit
  uint256 public maxGeneration = 10;
  /// @dev merkle tree root hash
  bytes32 public rootHash;
  /// @dev whitelist end time
  uint256 public whitelistEndTime;

  // Mappings for token metadata
  mapping(uint256 => uint256) public tokenCreationTimestamps;
  mapping(uint256 => uint256) public lastTokenTransferredTimestamp;
  mapping(uint256 => uint256) public tokenEntropy;
  mapping(uint256 => uint256) public generationMintCounts;
  mapping(uint256 => uint256) public tokenGenerations;
  mapping(uint256 => address) public initialOwners;

  uint256 private _tokenIds;

  modifier onlyWhitelisted(bytes32[] calldata proof, bytes32 leaf) {
    if (block.timestamp <= whitelistEndTime) {
      require(
        MerkleProof.verify(proof, rootHash, leaf),
        'Not whitelisted user'
      );
    }
    _;
  }

  constructor() ERC721('TraitForgeNft', 'TFGNFT') {
    whitelistEndTime = block.timestamp + 24 hours;
  }

  // Function to set the nuke fund contract address, restricted to the owner
  function setNukeFundContract(
    address payable _nukeFundAddress
  ) external onlyOwner {
    nukeFundAddress = _nukeFundAddress;
    emit NukeFundContractUpdated(_nukeFundAddress); // Consider adding an event for this.
  }

  // Function to set the entity merging (breeding) contract address, restricted to the owner
  function setEntityForgingContract(
    address entityForgingAddress_
  ) external onlyOwner {
    require(entityForgingAddress_ != address(0), 'Invalid address');

    entityForgingContract = IEntityForging(entityForgingAddress_);
  }

  function setEntropyGenerator(
    address entropyGeneratorAddress_
  ) external onlyOwner {
    require(entropyGeneratorAddress_ != address(0), 'Invalid address');

    entropyGenerator = IEntropyGenerator(entropyGeneratorAddress_);
  }

  function setAirdropContract(address airdrop_) external onlyOwner {
    require(airdrop_ != address(0), 'Invalid address');

    airdropContract = IAirdrop(airdrop_);
  }

  function startAirdrop(uint256 amount) external whenNotPaused onlyOwner {
    airdropContract.startAirdrop(amount);
  }

  function setStartPrice(uint256 _startPrice) external onlyOwner {
    startPrice = _startPrice;
  }

  function setPriceIncrement(uint256 _priceIncrement) external onlyOwner {
    priceIncrement = _priceIncrement;
  }

  function setPriceIncrementByGen(
    uint256 _priceIncrementByGen
  ) external onlyOwner {
    priceIncrementByGen = _priceIncrementByGen;
  }

  function setMaxGeneration(uint maxGeneration_) external onlyOwner {
    require(
      maxGeneration_ >= currentGeneration,
      "can't below than current generation"
    );
    maxGeneration = maxGeneration_;
  }

  function setRootHash(bytes32 rootHash_) external onlyOwner {
    rootHash = rootHash_;
  }

  function setWhitelistEndTime(uint256 endTime_) external onlyOwner {
    whitelistEndTime = endTime_;
  }

  function getGeneration() public view returns (uint256) {
    return currentGeneration;
  }

  function isApprovedOrOwner(
    address spender,
    uint256 tokenId
  ) public view returns (bool) {
    return _isApprovedOrOwner(spender, tokenId);
  }

  function burn(uint256 tokenId) external whenNotPaused nonReentrant {
    require(
      isApprovedOrOwner(msg.sender, tokenId),
      'ERC721: caller is not token owner or approved'
    );
    if (!airdropContract.airdropStarted()) {
      uint256 entropy = getTokenEntropy(tokenId);
      airdropContract.subUserAmount(initialOwners[tokenId], entropy);
    }
    _burn(tokenId);
  }

  function forge(
    address newOwner,
    uint256 parent1Id,
    uint256 parent2Id,
    string memory
  ) external whenNotPaused nonReentrant returns (uint256) {
    require(
      msg.sender == address(entityForgingContract),
      'unauthorized caller'
    );
    uint256 newGeneration = getTokenGeneration(parent1Id) + 1;

    /// Check new generation is not over maxGeneration
    require(newGeneration <= maxGeneration, "can't be over max generation");

    // Calculate the new entity's entropy
    (uint256 forgerEntropy, uint256 mergerEntropy) = getEntropiesForTokens(
      parent1Id,
      parent2Id
    );
    uint256 newEntropy = (forgerEntropy + mergerEntropy) / 2;

    // Mint the new entity
    uint256 newTokenId = _mintNewEntity(newOwner, newEntropy, newGeneration);

    return newTokenId;
  }

  function mintToken(
    bytes32[] calldata proof
  )
    public
    payable
    whenNotPaused
    nonReentrant
    onlyWhitelisted(proof, keccak256(abi.encodePacked(msg.sender)))
  {
    uint256 mintPrice = calculateMintPrice();
    require(msg.value >= mintPrice, 'Insufficient ETH send for minting.');

    _mintInternal(msg.sender, mintPrice);

    uint256 excessPayment = msg.value - mintPrice;
    if (excessPayment > 0) {
      (bool refundSuccess, ) = msg.sender.call{ value: excessPayment }('');
      require(refundSuccess, 'Refund of excess payment failed.');
    }
  }

  function mintWithBudget(
    bytes32[] calldata proof
  )
    public
    payable
    whenNotPaused
    nonReentrant
    onlyWhitelisted(proof, keccak256(abi.encodePacked(msg.sender)))
  {
    uint256 mintPrice = calculateMintPrice();
    uint256 amountMinted = 0;
    uint256 budgetLeft = msg.value;

    while (budgetLeft >= mintPrice && _tokenIds < maxTokensPerGen) {
      _mintInternal(msg.sender, mintPrice);
      amountMinted++;
      budgetLeft -= mintPrice;
      mintPrice = calculateMintPrice();
    }
    if (budgetLeft > 0) {
      (bool refundSuccess, ) = msg.sender.call{ value: budgetLeft }('');
      require(refundSuccess, 'Refund failed.');
    }
  }

  function calculateMintPrice() public view returns (uint256) {
    uint256 currentGenMintCount = generationMintCounts[currentGeneration];
    uint256 priceIncrease = priceIncrement * currentGenMintCount;
    uint256 price = startPrice + priceIncrease;
    return price;
  }

  function getTokenEntropy(uint256 tokenId) public view returns (uint256) {
    require(
      ownerOf(tokenId) != address(0),
      'ERC721: query for nonexistent token'
    );
    return tokenEntropy[tokenId];
  }

  function getTokenGeneration(uint256 tokenId) public view returns (uint256) {
    return tokenGenerations[tokenId];
  }

  function getEntropiesForTokens(
    uint256 forgerTokenId,
    uint256 mergerTokenId
  ) public view returns (uint256 forgerEntropy, uint256 mergerEntropy) {
    forgerEntropy = getTokenEntropy(forgerTokenId);
    mergerEntropy = getTokenEntropy(mergerTokenId);
  }

  function getTokenLastTransferredTimestamp(
    uint256 tokenId
  ) public view returns (uint256) {
    require(
      ownerOf(tokenId) != address(0),
      'ERC721: query for nonexistent token'
    );
    return lastTokenTransferredTimestamp[tokenId];
  }

  function getTokenCreationTimestamp(
    uint256 tokenId
  ) public view returns (uint256) {
    require(
      ownerOf(tokenId) != address(0),
      'ERC721: query for nonexistent token'
    );
    return tokenCreationTimestamps[tokenId];
  }

  function isForger(uint256 tokenId) public view returns (bool) {
    uint256 entropy = tokenEntropy[tokenId];
    uint256 roleIndicator = entropy % 3;
    return roleIndicator == 0;
  }

  function _mintInternal(address to, uint256 mintPrice) internal {
    if (generationMintCounts[currentGeneration] >= maxTokensPerGen) {
      _incrementGeneration();
    }

    _tokenIds++;
    uint256 newItemId = _tokenIds;
    _mint(to, newItemId);
    uint256 entropyValue = entropyGenerator.getNextEntropy();

    tokenCreationTimestamps[newItemId] = block.timestamp;
    tokenEntropy[newItemId] = entropyValue;
    tokenGenerations[newItemId] = currentGeneration;
    generationMintCounts[currentGeneration]++;
    initialOwners[newItemId] = to;

    if (!airdropContract.airdropStarted()) {
      airdropContract.addUserAmount(to, entropyValue);
    }

    emit Minted(
      msg.sender,
      newItemId,
      currentGeneration,
      entropyValue,
      mintPrice
    );

    _distributeFunds(mintPrice);
  }

  function _mintNewEntity(
    address newOwner,
    uint256 entropy,
    uint256 gen
  ) private returns (uint256) {
    require(
      generationMintCounts[gen] < maxTokensPerGen,
      'Exceeds maxTokensPerGen'
    );

    _tokenIds++;
    uint256 newTokenId = _tokenIds;
    _mint(newOwner, newTokenId);

    tokenCreationTimestamps[newTokenId] = block.timestamp;
    tokenEntropy[newTokenId] = entropy;
    tokenGenerations[newTokenId] = gen;
    generationMintCounts[gen]++;
    initialOwners[newTokenId] = newOwner;

    if (
      generationMintCounts[gen] >= maxTokensPerGen && gen == currentGeneration
    ) {
      _incrementGeneration();
    }

    if (!airdropContract.airdropStarted()) {
      airdropContract.addUserAmount(newOwner, entropy);
    }

    emit NewEntityMinted(newOwner, newTokenId, gen, entropy);
    return newTokenId;
  }

  function _incrementGeneration() private {
    require(
      generationMintCounts[currentGeneration] >= maxTokensPerGen,
      'Generation limit not yet reached'
    );
    currentGeneration++;
    generationMintCounts[currentGeneration] = 0;
    priceIncrement = priceIncrement + priceIncrementByGen;
    entropyGenerator.initializeAlphaIndices();
    emit GenerationIncremented(currentGeneration);
  }

  // distributes funds to nukeFund contract, where its then distrubted 10% dev 90% nukeFund
  function _distributeFunds(uint256 totalAmount) private {
    require(address(this).balance >= totalAmount, 'Insufficient balance');

    (bool success, ) = nukeFundAddress.call{ value: totalAmount }('');
    require(success, 'ETH send failed');

    emit FundsDistributedToNukeFund(nukeFundAddress, totalAmount);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 firstTokenId,
    uint256 batchSize
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

    uint listedId = entityForgingContract.getListedTokenIds(firstTokenId);
    /// @dev don't update the transferred timestamp if from and to address are same
    if (from != to) {
      lastTokenTransferredTimestamp[firstTokenId] = block.timestamp;
    }

    if (listedId > 0) {
      IEntityForging.Listing memory listing = entityForgingContract.getListings(
        listedId
      );
      if (
        listing.tokenId == firstTokenId &&
        listing.account == from &&
        listing.isListed
      ) {
        entityForgingContract.cancelListingForForging(firstTokenId);
      }
    }

    require(!paused(), 'ERC721Pausable: token transfer while paused');
  }
}