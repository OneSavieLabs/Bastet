// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ITransferManager} from "@looksrare/contracts-transfer-manager/contracts/interfaces/ITransferManager.sol";
import {TokenType as TransferManager__TokenType} from "@looksrare/contracts-transfer-manager/contracts/enums/TokenType.sol";
import {IERC20} from "@looksrare/contracts-libs/contracts/interfaces/generic/IERC20.sol";
import {SignatureCheckerMemory} from "@looksrare/contracts-libs/contracts/SignatureCheckerMemory.sol";
import {ReentrancyGuard} from "@looksrare/contracts-libs/contracts/ReentrancyGuard.sol";
import {Pausable} from "@looksrare/contracts-libs/contracts/Pausable.sol";

import {LowLevelWETH} from "@looksrare/contracts-libs/contracts/lowLevelCallers/LowLevelWETH.sol";
import {LowLevelERC20Transfer} from "@looksrare/contracts-libs/contracts/lowLevelCallers/LowLevelERC20Transfer.sol";
import {LowLevelERC721Transfer} from "@looksrare/contracts-libs/contracts/lowLevelCallers/LowLevelERC721Transfer.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import {IYoloV2} from "./interfaces/IYoloV2.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Arrays} from "./libraries/Arrays.sol";

//                                          @@@@@@@@@@@@@                                        @@@@@@@@@@@@@
// @@@@@@@@@@@@@@@       @@@@@@@@@@@@@@ @@@@%*+++++++++*%@@@@     @@@@@@@@@@@@@@             @@@@%+-:::::::-+%@@@@
//  @#:........=@@      @@*.........+@@@@*=================*@@@   @@=........=@@           @@@+.................+@@@
//  @@=........:#@@     @@.........:@@%+=====================+%@@ @@=........=@@         @@%-.....................-#@@
//  @@%:........=@@    @@=........:%@*=========================+%@@@=........=@@       @@%-.........................=@@@
//   @@+........:#@   @@#........:%%============================+#@@=........=@@      @@#:...........................:#@@
//    @@:........+@@  @@:.......:#%%@#*=======*%%@@@%%*==========+%@=........=@@      @#:.........:=*%%@%%#=..........:#@@
//    @@#........:%@ @@+........+%+==+#@@*==#@@@@   @@@@#=========+@#........=@@     @%-........:*@@@@   @@@@+:........-%@
//     @@=........=@@@#:.......-%*=======*@@@@         @@@=========*@:.......+@@    @@*.........@@@         @@%:........+@@
//      @%:.......:%@@=........=@+========*@@            @%=========@+.......+@@    @@-........%@@           @@*........=%@
//      @@+:.....:.-@#:.:......+@@@@@@@@@@@@             @@%%%%%%%%#@#::....:+@@    @@:.:.....:@@             @@::.:..:.-%@
//       @%-::::::::*-:::::::::@@*+++++++*@@             @@+++++++++@*:::::::+@@    @@:::::::::%@            @@%::::::::-%@
//       @@%********=:::::::::*@@*+*#%@@@##@@           @@*========+@=:::::::+@@    @@=::::::::=@@           @@=::::::::+@@
//        @@@@@@@@@@:::::::::=@@@@@#*++++++*@@        @@@+=========%@::::::::+@@     @%:::::::::=@@@       @@@=:::::::::#@@
//               @@=:::::::::%@ @@*++++++++++*@@@@@@@@@*+========+#@+::::::::+%@@@@@@@%+::::::::::+@@@@@@@@@+::::::::::+@@
//              @@#:::::::::*@@  @@*+++++++++*@#++++++==========+*@@+::::::::::::::::::::::::::::::::-===-::::::::::::=@@
//              @@-::::::::-%@    @@#++++++++%%+===============+#@@@+::::::::::::::::::::::::::::::::::::::::::::::::*@@
//             @@+:::::::::*@@     @@@*+++++%%+===============*%@@@@+:::::::::::::::::::::*=:::::::::::::::::::::::=%@@
//             @%-::::::::=@@        @@@#++#@*+============+*@@@  @@+:::::::::::::::::::::%@%+-::::::::::::::::::+%@@
//            @@%*********%@@          @@@@@*+==========+#@@@@    @@#*********************%@@@@@*-:::::::::::-*@@@@
//            @@@@@@@@@@@@@@              @@@@@@@%%%@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@   @@@@@@@%%%@@@@@@@
//                                               @@@@                                                @@@@@

/**
 * @title YoloV2
 * @notice This contract permissionlessly hosts yolos on LooksRare.
 * @author LooksRare protocol team (👀,💎)
 */
contract YoloV2 is
    IYoloV2,
    AccessControl,
    VRFConsumerBaseV2,
    LowLevelWETH,
    LowLevelERC20Transfer,
    LowLevelERC721Transfer,
    ReentrancyGuard,
    Pausable
{
    using Arrays for uint256[];

    /**
     * @notice Operators are allowed to add/remove allowed ERC-20 and ERC-721 tokens.
     */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /**
     * @notice The TWAP period in seconds to use.
     */
    uint256 private constant TWAP_DURATION = 3_600;

    /**
     * @notice The maximum protocol fee in basis points, which is 25%.
     */
    uint16 public constant MAXIMUM_PROTOCOL_FEE_BP = 2_500;

    /**
     * @notice The maximum number of deposits per round.
     */
    uint256 private constant MAXIMUM_NUMBER_OF_DEPOSITS_PER_ROUND = 100;

    /**
     * @notice Reservoir oracle's message typehash.
     * @dev It is used to compute the hash of the message using the (message) id, the payload, and the timestamp.
     */
    bytes32 private constant RESERVOIR_ORACLE_MESSAGE_TYPEHASH =
        keccak256("Message(bytes32 id,bytes payload,uint256 timestamp,uint256 chainId)");

    /**
     * @notice Reservoir oracle's ID typehash.
     * @dev It is used to compute the hash of the ID using price kind, TWAP seconds, and the contract address.
     */
    bytes32 private constant RESERVOIR_ORACLE_ID_TYPEHASH =
        keccak256(
            "ContractWideCollectionPrice(uint8 kind,uint256 twapSeconds,address contract,bool onlyNonFlaggedTokens)"
        );

    /**
     * @notice The bits offset of the round's maximum number of participants in a round slot.
     */
    uint256 private constant ROUND__MAXIMUM_NUMBER_OF_PARTICIPANTS_OFFSET = 8;

    /**
     * @notice The bits offset of the round's protocol fee basis points in a round slot.
     */
    uint256 private constant ROUND__PROTOCOL_FEE_BP_OFFSET = 48;

    /**
     * @notice The bits offset of the round's cutoff time in a round slot.
     */
    uint256 private constant ROUND__CUTOFF_TIME_OFFSET = 64;

    /**
     * @notice The bits offset of the round's value per entry in a round slot.
     */
    uint256 private constant ROUND__VALUE_PER_ENTRY_OFFSET = 160;

    /**
     * @notice The slot offset of the round's value per entry starting from the round's slot.
     */
    uint256 private constant ROUND__VALUE_PER_ENTRY_SLOT_OFFSET = 1;

    /**
     * @notice The bits offset of the randomness request's round ID in a randomness request slot.
     */
    uint256 private constant RANDOMNESS_REQUEST__ROUND_ID_OFFSET = 8;

    /**
     * @notice The slot offset of the round's deposits length starting from the round's slot.
     */
    uint256 private constant ROUND__DEPOSITS_LENGTH_SLOT_OFFSET = 3;

    /**
     * @notice The number of slots a round struct occupies.
     */
    uint256 private constant DEPOSIT__OCCUPIED_SLOTS = 4;

    /**
     * @notice The slot offset of the deposit's token ID starting from the deposit's slot.
     */
    uint256 private constant DEPOSIT__TOKEN_ID_SLOT_OFFSET = 1;

    /**
     * @notice The slot offset of the deposit's token amount starting from the deposit's slot.
     */
    uint256 private constant DEPOSIT__TOKEN_AMOUNT_SLOT_OFFSET = 2;

    /**
     * @notice The slot offset of the deposit's last slot starting from the deposit's slot.
     */
    uint256 private constant DEPOSIT__LAST_SLOT_OFFSET = 3;

    /**
     * @notice The bits offset of the deposit's token address in the deposit's slot 0.
     */
    uint256 private constant DEPOSIT__TOKEN_ADDRESS_OFFSET = 8;

    /**
     * @notice The bits offset of the deposit's current entry index in the deposit's slot 3.
     */
    uint256 private constant DEPOSIT__CURRENT_ENTRY_INDEX_OFFSET = 168;

    /**
     * @notice Wrapped Ether address.
     */
    address private immutable WETH;

    /**
     * @notice The key hash of the Chainlink VRF.
     */
    bytes32 private immutable KEY_HASH;

    /**
     * @notice The subscription ID of the Chainlink VRF.
     */
    uint64 public immutable SUBSCRIPTION_ID;

    /**
     * @notice The Chainlink VRF coordinator.
     */
    VRFCoordinatorV2Interface private immutable VRF_COORDINATOR;

    /**
     * @notice Transfer manager faciliates token transfers.
     */
    ITransferManager private immutable transferManager;

    /**
     * @notice LOOKS token address.
     */
    address private immutable LOOKS;

    /**
     * @notice The value of each entry in ETH.
     */
    uint96 public valuePerEntry;

    /**
     * @notice The duration of each round.
     */
    uint40 public roundDuration;

    /**
     * @notice The protocol fee basis points.
     */
    uint16 public protocolFeeBp;

    /**
     * @notice The protocol fee discount basis points if paid with LOOKS.
     */
    uint16 public protocolFeeDiscountBp;

    /**
     * @notice Number of rounds that have been created.
     * @dev In this smart contract, roundId is an uint256 but its
     *      max value can only be 2^40 - 1. Realistically we will still
     *      not reach this number.
     */
    uint40 public roundsCount;

    /**
     * @notice The maximum number of participants per round.
     */
    uint40 public maximumNumberOfParticipantsPerRound;

    /**
     * @notice Whether token outflow is allowed.
     */
    bool public outflowAllowed = true;

    /**
     * @notice The address of the protocol fee recipient.
     */
    address public protocolFeeRecipient;

    /**
     * @notice ERC-20 oracle address.
     */
    IPriceOracle public erc20Oracle;

    /**
     * @notice Reservoir oracle address.
     */
    address public reservoirOracle;

    /**
     * @notice Reservoir oracle's signature validity period.
     */
    uint40 public signatureValidityPeriod;

    /**
     * @notice It checks whether the currency is allowed.
     * @dev 0 is not allowed, 1 is allowed.
     */
    mapping(address currency => uint256 isAllowed) public isCurrencyAllowed;

    mapping(uint256 roundId => Round) private rounds;

    /**
     * @notice The deposit count of a user in any given round.
     */
    mapping(uint256 roundId => mapping(address depositor => uint256 depositCount)) public depositCount;

    /**
     * @notice Chainlink randomness requests.
     */
    mapping(uint256 requestId => RandomnessRequest) public randomnessRequests;

    /**
     * @notice The price of an ERC-20/ERC-712 token or a collection in any given round.
     */
    mapping(address tokenOrCollection => mapping(uint256 roundId => uint256 price)) public prices;

    /**
     * @param params The constructor params.
     */
    constructor(ConstructorCalldata memory params) VRFConsumerBaseV2(params.vrfCoordinator) {
        _grantRole(DEFAULT_ADMIN_ROLE, params.owner);
        _grantRole(OPERATOR_ROLE, params.operator);
        _updateRoundDuration(params.roundDuration);
        _updateProtocolFeeRecipient(params.protocolFeeRecipient);
        _updateProtocolFeeBp(params.protocolFeeBp);
        _updateProtocolFeeDiscountBp(params.protocolFeeDiscountBp);
        _updateValuePerEntry(params.valuePerEntry);
        _updateERC20Oracle(params.erc20Oracle);
        _updateMaximumNumberOfParticipantsPerRound(params.maximumNumberOfParticipantsPerRound);
        _updateReservoirOracle(params.reservoirOracle);
        _updateSignatureValidityPeriod(params.signatureValidityPeriod);

        WETH = params.weth;
        KEY_HASH = params.keyHash;
        VRF_COORDINATOR = VRFCoordinatorV2Interface(params.vrfCoordinator);
        SUBSCRIPTION_ID = params.subscriptionId;
        LOOKS = params.looks;

        transferManager = ITransferManager(params.transferManager);

        _startRound({_roundsCount: 0});
    }

    /**
     * @inheritdoc IYoloV2
     */
    function deposit(uint256 roundId, DepositCalldata[] calldata deposits) external payable nonReentrant whenNotPaused {
        _deposit(roundId, deposits);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function depositETHIntoMultipleRounds(uint256[] calldata amounts) external payable nonReentrant whenNotPaused {
        uint256 numberOfRounds = amounts.length;
        if (msg.value == 0 || numberOfRounds == 0) {
            revert ZeroDeposits();
        }

        uint256 startingRoundId = roundsCount;
        Round storage startingRound = rounds[startingRoundId];
        _validateRoundIsOpen(startingRound);

        _setCutoffTimeIfNotSet(startingRound);

        uint256 expectedValue;
        uint256[] memory entriesCounts = new uint256[](numberOfRounds);

        for (uint256 i; i < numberOfRounds; ++i) {
            uint256 roundId = _unsafeAdd(startingRoundId, i);
            Round storage round = rounds[roundId];
            uint256 roundValuePerEntry = round.valuePerEntry;
            if (roundValuePerEntry == 0) {
                (, , roundValuePerEntry) = _writeDataToRound({roundId: roundId, roundValue: 0});
            }

            _incrementUserDepositCount(roundId, round);

            uint256 depositAmount = amounts[i];
            if (depositAmount % roundValuePerEntry != 0) {
                revert InvalidValue();
            }
            uint256 entriesCount = _depositETH(round, roundId, roundValuePerEntry, depositAmount);
            expectedValue += depositAmount;

            entriesCounts[i] = entriesCount;
        }

        if (expectedValue != msg.value) {
            revert InvalidValue();
        }

        emit MultipleRoundsDeposited(msg.sender, startingRoundId, amounts, entriesCounts);

        if (
            _shouldDrawWinner(
                startingRound.numberOfParticipants,
                startingRound.maximumNumberOfParticipants,
                startingRound.deposits.length
            )
        ) {
            _drawWinner(startingRound, startingRoundId);
        }
    }

    /**
     * @inheritdoc IYoloV2
     */
    function getRound(
        uint256 roundId
    )
        external
        view
        returns (
            RoundStatus status,
            uint40 maximumNumberOfParticipants,
            uint16 roundProtocolFeeBp,
            uint40 cutoffTime,
            uint40 drawnAt,
            uint40 numberOfParticipants,
            address winner,
            uint96 roundValuePerEntry,
            uint256 protocolFeeOwed,
            Deposit[] memory deposits
        )
    {
        Round memory round = rounds[roundId];
        status = round.status;
        maximumNumberOfParticipants = round.maximumNumberOfParticipants;
        roundProtocolFeeBp = round.protocolFeeBp;
        cutoffTime = round.cutoffTime;
        drawnAt = round.drawnAt;
        numberOfParticipants = round.numberOfParticipants;
        winner = round.winner;
        roundValuePerEntry = round.valuePerEntry;
        protocolFeeOwed = round.protocolFeeOwed;
        deposits = round.deposits;
    }

    /**
     * @inheritdoc IYoloV2
     */
    function drawWinner() external nonReentrant whenNotPaused {
        uint256 roundId = roundsCount;
        Round storage round = rounds[roundId];

        _validateRoundStatus(round, RoundStatus.Open);

        if (block.timestamp < round.cutoffTime) {
            revert CutoffTimeNotReached();
        }

        if (round.numberOfParticipants < 2) {
            revert InsufficientParticipants();
        }

        _drawWinner(round, roundId);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function cancel() external nonReentrant {
        _validateOutflowIsAllowed();
        _cancel({roundId: roundsCount});
    }

    /**
     * @inheritdoc IYoloV2
     */
    function cancel(uint256 numberOfRounds) external {
        _validateIsOwner();

        if (numberOfRounds == 0) {
            revert ZeroRounds();
        }

        uint256 startingRoundId = roundsCount;

        for (uint256 i; i < numberOfRounds; ++i) {
            uint256 roundId = _unsafeAdd(startingRoundId, i);
            rounds[roundId].status = RoundStatus.Cancelled;
        }

        emit RoundsCancelled(startingRoundId, numberOfRounds);

        _startRound({_roundsCount: _unsafeSubtract(_unsafeAdd(startingRoundId, numberOfRounds), 1)});
    }

    /**
     * @inheritdoc IYoloV2
     */
    function cancelAfterRandomnessRequest() external nonReentrant {
        _validateOutflowIsAllowed();

        uint256 roundId = roundsCount;
        Round storage round = rounds[roundId];

        _validateRoundStatus(round, RoundStatus.Drawing);

        if (block.timestamp < round.drawnAt + 1 days) {
            revert DrawExpirationTimeNotReached();
        }

        round.status = RoundStatus.Cancelled;

        emit RoundStatusUpdated(roundId, RoundStatus.Cancelled);

        _startRound({_roundsCount: roundId});
    }

    /**
     * @inheritdoc IYoloV2
     */
    function claimPrizes(
        WithdrawalCalldata[] calldata withdrawalCalldata,
        bool payWithLOOKS
    ) external payable nonReentrant {
        _validateOutflowIsAllowed();

        TransferAccumulator memory transferAccumulator;
        uint256 ethAmount;
        uint256 protocolFeeOwed;

        _validateArrayLengthIsNotEmpty(withdrawalCalldata.length);

        if (payWithLOOKS) {
            if (msg.value != 0) {
                revert InvalidValue();
            }
        }

        for (uint256 i; i < withdrawalCalldata.length; ++i) {
            WithdrawalCalldata calldata perRoundWithdrawalCalldata = withdrawalCalldata[i];

            Round storage round = rounds[perRoundWithdrawalCalldata.roundId];

            _validateRoundStatus(round, RoundStatus.Drawn);
            _validateMsgSenderIsWinner(round);

            uint256[] calldata depositIndices = perRoundWithdrawalCalldata.depositIndices;
            _validateArrayLengthIsNotEmpty(depositIndices.length);

            for (uint256 j; j < depositIndices.length; ++j) {
                uint256 index = depositIndices[j];
                _validateDepositsArrayIndex(index, round);
                ethAmount = _transferTokenOut(round.deposits[index], transferAccumulator, ethAmount);
            }

            protocolFeeOwed += round.protocolFeeOwed;
            round.protocolFeeOwed = 0;
        }

        if (protocolFeeOwed != 0) {
            if (payWithLOOKS) {
                protocolFeeOwed = _protocolFeeOwedInLOOKS(protocolFeeOwed);

                transferManager.transferERC20(LOOKS, msg.sender, protocolFeeRecipient, protocolFeeOwed);

                emit ProtocolFeePayment(protocolFeeOwed, LOOKS);
            } else {
                _transferETHAndWrapIfFailWithGasLimit(WETH, protocolFeeRecipient, protocolFeeOwed, gasleft());

                emit ProtocolFeePayment(protocolFeeOwed, address(0));

                protocolFeeOwed -= msg.value;
                if (protocolFeeOwed <= ethAmount) {
                    unchecked {
                        ethAmount -= protocolFeeOwed;
                    }
                } else {
                    revert ProtocolFeeNotPaid();
                }
            }
        }

        if (transferAccumulator.amount != 0) {
            _executeERC20DirectTransfer(transferAccumulator.tokenAddress, msg.sender, transferAccumulator.amount);
        }

        if (ethAmount != 0) {
            _transferETHAndWrapIfFailWithGasLimit(WETH, msg.sender, ethAmount, gasleft());
        }

        emit PrizesClaimed(msg.sender, withdrawalCalldata);
    }

    /**
     * @inheritdoc IYoloV2
     * @dev This function does not validate withdrawalCalldata to not contain duplicate round IDs and prize indices.
     *      It is the responsibility of the caller to ensure that. Otherwise, the returned protocol fee owed will be incorrect.
     */
    function getClaimPrizesPaymentRequired(
        WithdrawalCalldata[] calldata withdrawalCalldata,
        bool payWithLOOKS
    ) external view returns (uint256 protocolFeeOwed) {
        uint256 ethAmount;

        for (uint256 i; i < withdrawalCalldata.length; ++i) {
            WithdrawalCalldata calldata perRoundWithdrawalCalldata = withdrawalCalldata[i];
            Round storage round = rounds[perRoundWithdrawalCalldata.roundId];

            _validateRoundStatus(round, RoundStatus.Drawn);

            uint256[] calldata depositIndices = perRoundWithdrawalCalldata.depositIndices;
            uint256 numberOfPrizes = depositIndices.length;
            uint256 prizesCount = round.deposits.length;

            for (uint256 j; j < numberOfPrizes; ++j) {
                uint256 index = depositIndices[j];
                if (index >= prizesCount) {
                    revert InvalidIndex();
                }

                Deposit storage prize = round.deposits[index];
                if (prize.tokenType == YoloV2__TokenType.ETH) {
                    ethAmount += prize.tokenAmount;
                }
            }

            protocolFeeOwed += round.protocolFeeOwed;
        }

        if (payWithLOOKS) {
            protocolFeeOwed = _protocolFeeOwedInLOOKS(protocolFeeOwed);
        } else {
            if (protocolFeeOwed < ethAmount) {
                protocolFeeOwed = 0;
            } else {
                unchecked {
                    protocolFeeOwed -= ethAmount;
                }
            }
        }
    }

    /**
     * @inheritdoc IYoloV2
     */
    function withdrawDeposits(WithdrawalCalldata[] calldata withdrawalCalldata) external nonReentrant {
        _validateOutflowIsAllowed();

        TransferAccumulator memory transferAccumulator;
        uint256 ethAmount;

        _validateArrayLengthIsNotEmpty(withdrawalCalldata.length);

        for (uint256 i; i < withdrawalCalldata.length; ++i) {
            WithdrawalCalldata calldata perRoundWithdrawalCalldata = withdrawalCalldata[i];

            Round storage round = rounds[perRoundWithdrawalCalldata.roundId];

            _validateRoundStatus(round, RoundStatus.Cancelled);

            uint256[] calldata depositIndices = perRoundWithdrawalCalldata.depositIndices;
            uint256 depositIndicesLength = depositIndices.length;
            _validateArrayLengthIsNotEmpty(depositIndicesLength);

            for (uint256 j; j < depositIndicesLength; ++j) {
                uint256 index = depositIndices[j];
                _validateDepositsArrayIndex(index, round);

                Deposit storage singleDeposit = round.deposits[index];

                _validateMsgSenderIsDepositor(singleDeposit);

                ethAmount = _transferTokenOut(singleDeposit, transferAccumulator, ethAmount);
            }
        }

        if (transferAccumulator.amount != 0) {
            _executeERC20DirectTransfer(transferAccumulator.tokenAddress, msg.sender, transferAccumulator.amount);
        }

        if (ethAmount != 0) {
            _transferETHAndWrapIfFailWithGasLimit(WETH, msg.sender, ethAmount, gasleft());
        }

        emit DepositsWithdrawn(msg.sender, withdrawalCalldata);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function rolloverETH(
        WithdrawalCalldata[] calldata withdrawalCalldata,
        bool payWithLOOKS
    ) external nonReentrant whenNotPaused {
        uint256 rolloverAmount;
        uint256 protocolFeeOwed;

        uint256 withdrawalCalldataLength = withdrawalCalldata.length;
        _validateArrayLengthIsNotEmpty(withdrawalCalldataLength);

        for (uint256 i; i < withdrawalCalldataLength; ++i) {
            WithdrawalCalldata calldata perRoundWithdrawalCalldata = withdrawalCalldata[i];

            Round storage cancelledOrDrawnRound = rounds[perRoundWithdrawalCalldata.roundId];

            RoundStatus status = cancelledOrDrawnRound.status;
            if (status < RoundStatus.Drawn) {
                revert InvalidStatus();
            }

            if (status == RoundStatus.Drawn) {
                _validateMsgSenderIsWinner(cancelledOrDrawnRound);
                protocolFeeOwed += cancelledOrDrawnRound.protocolFeeOwed;
                cancelledOrDrawnRound.protocolFeeOwed = 0;
            }

            uint256[] calldata depositIndices = perRoundWithdrawalCalldata.depositIndices;
            uint256 depositIndicesLength = depositIndices.length;
            _validateArrayLengthIsNotEmpty(depositIndicesLength);

            for (uint256 j; j < depositIndicesLength; ++j) {
                uint256 index = depositIndices[j];
                _validateDepositsArrayIndex(index, cancelledOrDrawnRound);

                Deposit storage singleDeposit = cancelledOrDrawnRound.deposits[index];

                _validateDepositNotWithdrawn(singleDeposit);

                if (singleDeposit.tokenType != YoloV2__TokenType.ETH) {
                    revert InvalidTokenType();
                }

                if (status == RoundStatus.Cancelled) {
                    _validateMsgSenderIsDepositor(singleDeposit);
                }

                singleDeposit.withdrawn = true;

                rolloverAmount += singleDeposit.tokenAmount;
            }
        }

        if (protocolFeeOwed != 0) {
            if (payWithLOOKS) {
                protocolFeeOwed = _protocolFeeOwedInLOOKS(protocolFeeOwed);
                transferManager.transferERC20(LOOKS, msg.sender, protocolFeeRecipient, protocolFeeOwed);

                emit ProtocolFeePayment(protocolFeeOwed, LOOKS);
            } else {
                if (rolloverAmount < protocolFeeOwed) {
                    revert ProtocolFeeNotPaid();
                } else {
                    unchecked {
                        rolloverAmount -= protocolFeeOwed;
                    }
                }

                _transferETHAndWrapIfFailWithGasLimit(WETH, protocolFeeRecipient, protocolFeeOwed, gasleft());

                emit ProtocolFeePayment(protocolFeeOwed, address(0));
            }
        }

        uint256 roundId = roundsCount;
        Round storage round = rounds[roundId];
        _validateRoundIsOpen(round);

        _incrementUserDepositCount(roundId, round);
        _setCutoffTimeIfNotSet(round);

        uint256 roundValuePerEntry = round.valuePerEntry;
        uint256 dust = rolloverAmount % roundValuePerEntry;
        if (dust != 0) {
            unchecked {
                rolloverAmount -= dust;
            }
            _transferETHAndWrapIfFailWithGasLimit(WETH, msg.sender, dust, gasleft());
        }

        if (rolloverAmount < roundValuePerEntry) {
            revert InvalidValue();
        }

        uint256 entriesCount = _depositETH(round, roundId, roundValuePerEntry, rolloverAmount);

        if (_shouldDrawWinner(round.numberOfParticipants, round.maximumNumberOfParticipants, round.deposits.length)) {
            _drawWinner(round, roundId);
        }

        emit Rollover(msg.sender, withdrawalCalldata, roundId, entriesCount);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function togglePaused() external {
        _validateIsOwner();
        paused() ? _unpause() : _pause();
    }

    /**
     * @inheritdoc IYoloV2
     */
    function toggleOutflowAllowed() external {
        _validateIsOwner();
        bool _outflowAllowed = outflowAllowed;
        outflowAllowed = !_outflowAllowed;
        emit OutflowAllowedUpdated(!_outflowAllowed);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateCurrenciesStatus(address[] calldata currencies, bool isAllowed) external {
        _validateIsOperator();

        uint256 count = currencies.length;
        for (uint256 i; i < count; ++i) {
            isCurrencyAllowed[currencies[i]] = (isAllowed ? 1 : 0);
        }
        emit CurrenciesStatusUpdated(currencies, isAllowed);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateRoundDuration(uint40 _roundDuration) external {
        _validateIsOwner();
        _updateRoundDuration(_roundDuration);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateSignatureValidityPeriod(uint40 _signatureValidityPeriod) external {
        _validateIsOwner();
        _updateSignatureValidityPeriod(_signatureValidityPeriod);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateValuePerEntry(uint96 _valuePerEntry) external {
        _validateIsOwner();
        _updateValuePerEntry(_valuePerEntry);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateProtocolFeeRecipient(address _protocolFeeRecipient) external {
        _validateIsOwner();
        _updateProtocolFeeRecipient(_protocolFeeRecipient);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateProtocolFeeBp(uint16 _protocolFeeBp) external {
        _validateIsOwner();
        _updateProtocolFeeBp(_protocolFeeBp);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateProtocolFeeDiscountBp(uint16 _protocolFeeDiscountBp) external {
        _validateIsOwner();
        _updateProtocolFeeDiscountBp(_protocolFeeDiscountBp);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateMaximumNumberOfParticipantsPerRound(uint40 _maximumNumberOfParticipantsPerRound) external {
        _validateIsOwner();
        _updateMaximumNumberOfParticipantsPerRound(_maximumNumberOfParticipantsPerRound);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateReservoirOracle(address _reservoirOracle) external {
        _validateIsOwner();
        _updateReservoirOracle(_reservoirOracle);
    }

    /**
     * @inheritdoc IYoloV2
     */
    function updateERC20Oracle(address _erc20Oracle) external {
        _validateIsOwner();
        _updateERC20Oracle(_erc20Oracle);
    }

    /**
     * @param _roundDuration The duration of each round.
     */
    function _updateRoundDuration(uint40 _roundDuration) private {
        if (_roundDuration > 1 hours) {
            revert InvalidRoundDuration();
        }

        roundDuration = _roundDuration;
        emit RoundDurationUpdated(_roundDuration);
    }

    /**
     * @param _signatureValidityPeriod The validity period of a Reservoir signature.
     */
    function _updateSignatureValidityPeriod(uint40 _signatureValidityPeriod) private {
        signatureValidityPeriod = _signatureValidityPeriod;
        emit SignatureValidityPeriodUpdated(_signatureValidityPeriod);
    }

    /**
     * @param _valuePerEntry The value of each entry in ETH.
     */
    function _updateValuePerEntry(uint96 _valuePerEntry) private {
        if (_valuePerEntry == 0) {
            revert InvalidValue();
        }
        valuePerEntry = _valuePerEntry;
        emit ValuePerEntryUpdated(_valuePerEntry);
    }

    /**
     * @param _protocolFeeRecipient The new protocol fee recipient address
     */
    function _updateProtocolFeeRecipient(address _protocolFeeRecipient) private {
        if (_protocolFeeRecipient == address(0)) {
            revert InvalidValue();
        }
        protocolFeeRecipient = _protocolFeeRecipient;
        emit ProtocolFeeRecipientUpdated(_protocolFeeRecipient);
    }

    /**
     * @param _protocolFeeBp The new protocol fee in basis points
     */
    function _updateProtocolFeeBp(uint16 _protocolFeeBp) private {
        if (_protocolFeeBp > MAXIMUM_PROTOCOL_FEE_BP) {
            revert InvalidValue();
        }
        protocolFeeBp = _protocolFeeBp;
        emit ProtocolFeeBpUpdated(_protocolFeeBp);
    }

    /**
     * @param _protocolFeeDiscountBp The new protocol fee in basis points
     */
    function _updateProtocolFeeDiscountBp(uint16 _protocolFeeDiscountBp) private {
        if (_protocolFeeDiscountBp > 10_000) {
            revert InvalidValue();
        }
        protocolFeeDiscountBp = _protocolFeeDiscountBp;
        emit ProtocolFeeDiscountBpUpdated(_protocolFeeDiscountBp);
    }

    /**
     * @param _maximumNumberOfParticipantsPerRound The new maximum number of participants per round
     */
    function _updateMaximumNumberOfParticipantsPerRound(uint40 _maximumNumberOfParticipantsPerRound) private {
        if (_maximumNumberOfParticipantsPerRound < 2) {
            revert InvalidValue();
        }
        maximumNumberOfParticipantsPerRound = _maximumNumberOfParticipantsPerRound;
        emit MaximumNumberOfParticipantsPerRoundUpdated(_maximumNumberOfParticipantsPerRound);
    }

    /**
     * @param _reservoirOracle The new Reservoir oracle address
     */
    function _updateReservoirOracle(address _reservoirOracle) private {
        if (_reservoirOracle == address(0)) {
            revert InvalidValue();
        }
        reservoirOracle = _reservoirOracle;
        emit ReservoirOracleUpdated(_reservoirOracle);
    }

    /**
     * @param _erc20Oracle The new ERC-20 oracle address
     */
    function _updateERC20Oracle(address _erc20Oracle) private {
        if (_erc20Oracle == address(0)) {
            revert InvalidValue();
        }
        erc20Oracle = IPriceOracle(_erc20Oracle);
        emit ERC20OracleUpdated(_erc20Oracle);
    }

    /**
     * @param _roundsCount The current rounds count
     * @return roundId The started round ID
     */
    function _startRound(uint256 _roundsCount) private returns (uint256 roundId) {
        unchecked {
            roundId = _roundsCount + 1;
        }
        roundsCount = uint40(roundId);

        Round storage round = rounds[roundId];

        if (round.valuePerEntry == 0) {
            // On top of the 4 values covered by _writeDataToRound, this also writes the round's status to Open (1).
            _writeDataToRound({roundId: roundId, roundValue: 1});
            emit RoundStatusUpdated(roundId, RoundStatus.Open);
        } else {
            uint256 numberOfParticipants = round.numberOfParticipants;

            if (
                !paused() &&
                _shouldDrawWinner(numberOfParticipants, round.maximumNumberOfParticipants, round.deposits.length)
            ) {
                _drawWinner(round, roundId);
            } else {
                uint40 _roundDuration = roundDuration;
                // This is equivalent to
                // round.status = RoundStatus.Open;
                // if (round.numberOfParticipants > 0) {
                //   round.cutoffTime = uint40(block.timestamp) + _roundDuration;
                // }
                uint256 roundSlot = _getRoundSlot(roundId);
                assembly {
                    // RoundStatus.Open is equal to 1.
                    let roundValue := or(sload(roundSlot), 1)

                    if gt(numberOfParticipants, 0) {
                        roundValue := or(roundValue, shl(ROUND__CUTOFF_TIME_OFFSET, add(timestamp(), _roundDuration)))
                    }

                    sstore(roundSlot, roundValue)
                }

                emit RoundStatusUpdated(roundId, RoundStatus.Open);
            }
        }
    }

    /**
     * @param round The open round.
     * @param roundId The open round ID.
     */
    function _drawWinner(Round storage round, uint256 roundId) private {
        round.status = RoundStatus.Drawing;
        round.drawnAt = uint40(block.timestamp);

        uint256 requestId = VRF_COORDINATOR.requestRandomWords({
            keyHash: KEY_HASH,
            subId: SUBSCRIPTION_ID,
            minimumRequestConfirmations: uint16(3),
            callbackGasLimit: uint32(500_000),
            numWords: uint32(1)
        });

        if (randomnessRequests[requestId].exists) {
            revert RandomnessRequestAlreadyExists();
        }

        // This is equivalent to
        // randomnessRequests[requestId].exists = true;
        // randomnessRequests[requestId].roundId = uint40(roundId);
        assembly {
            mstore(0x00, requestId)
            mstore(0x20, randomnessRequests.slot)
            let randomnessRequestSlot := keccak256(0x00, 0x40)

            // 1 is true
            sstore(randomnessRequestSlot, or(1, shl(RANDOMNESS_REQUEST__ROUND_ID_OFFSET, roundId)))
        }

        emit RandomnessRequested(roundId, requestId);
        emit RoundStatusUpdated(roundId, RoundStatus.Drawing);
    }

    /**
     * @param roundId The open round ID.
     * @param deposits The ERC-20/ERC-721 deposits to be made.
     */
    function _deposit(uint256 roundId, DepositCalldata[] calldata deposits) private {
        Round storage round = rounds[roundId];
        _validateRoundIsOpen(round);

        _incrementUserDepositCount(roundId, round);
        _setCutoffTimeIfNotSet(round);

        uint256 roundDepositCount = round.deposits.length;
        uint40 currentEntryIndex;
        uint256 totalEntriesCount;

        uint256 roundDepositsLengthSlot = _getRoundSlot(roundId) + ROUND__DEPOSITS_LENGTH_SLOT_OFFSET;

        if (msg.value == 0) {
            if (deposits.length == 0) {
                revert ZeroDeposits();
            }
        } else {
            uint256 roundValuePerEntry = round.valuePerEntry;
            if (msg.value % roundValuePerEntry != 0) {
                revert InvalidValue();
            }
            uint256 entriesCount = msg.value / roundValuePerEntry;
            totalEntriesCount += entriesCount;

            currentEntryIndex = _getCurrentEntryIndexWithoutAccrual(round, roundDepositCount, entriesCount);

            // This is equivalent to
            // round.deposits.push(
            //     Deposit({
            //         tokenType: YoloV2__TokenType.ETH,
            //         tokenAddress: address(0),
            //         tokenId: 0,
            //         tokenAmount: msg.value,
            //         depositor: msg.sender,
            //         withdrawn: false,
            //         currentEntryIndex: currentEntryIndex
            //     })
            // );
            uint256 depositDataSlotWithCountOffset = _getDepositDataSlotWithCountOffset(
                roundDepositsLengthSlot,
                roundDepositCount
            );
            // We don't have to write tokenType, tokenAddress, tokenId, and withdrawn because they are 0.
            _writeDepositorAndCurrentEntryIndexToDeposit(depositDataSlotWithCountOffset, currentEntryIndex);
            _writeDepositAmountToDeposit(depositDataSlotWithCountOffset, msg.value);
            unchecked {
                ++roundDepositCount;
            }
        }

        if (deposits.length != 0) {
            ITransferManager.BatchTransferItem[] memory batchTransferItems = new ITransferManager.BatchTransferItem[](
                deposits.length
            );

            for (uint256 i; i < deposits.length; ++i) {
                DepositCalldata calldata singleDeposit = deposits[i];
                address tokenAddress = singleDeposit.tokenAddress;
                if (isCurrencyAllowed[tokenAddress] != 1) {
                    revert InvalidCollection();
                }
                uint256 price = prices[tokenAddress][roundId];
                if (singleDeposit.tokenType == YoloV2__TokenType.ERC721) {
                    if (price == 0) {
                        price = _getReservoirPrice(singleDeposit);
                        prices[tokenAddress][roundId] = price;
                    }

                    uint256 entriesCount = price / round.valuePerEntry;
                    if (entriesCount == 0) {
                        revert InvalidValue();
                    }

                    uint256[] memory amounts = new uint256[](singleDeposit.tokenIdsOrAmounts.length);
                    for (uint256 j; j < singleDeposit.tokenIdsOrAmounts.length; ++j) {
                        totalEntriesCount += entriesCount;

                        if (currentEntryIndex != 0) {
                            currentEntryIndex += uint40(entriesCount);
                        } else {
                            currentEntryIndex = _getCurrentEntryIndexWithoutAccrual(
                                round,
                                roundDepositCount,
                                entriesCount
                            );
                        }

                        uint256 tokenId = singleDeposit.tokenIdsOrAmounts[j];

                        // tokenAmount is in reality 1, but we never use it and it is cheaper to set it as 0.
                        // This is equivalent to
                        // round.deposits.push(
                        //     Deposit({
                        //         tokenType: YoloV2__TokenType.ERC721,
                        //         tokenAddress: tokenAddress,
                        //         tokenId: tokenId,
                        //         tokenAmount: 0,
                        //         depositor: msg.sender,
                        //         withdrawn: false,
                        //         currentEntryIndex: currentEntryIndex
                        //     })
                        // );
                        // unchecked {
                        //     roundDepositCount += 1;
                        // }
                        uint256 depositDataSlotWithCountOffset = _getDepositDataSlotWithCountOffset(
                            roundDepositsLengthSlot,
                            roundDepositCount
                        );
                        _writeDepositorAndCurrentEntryIndexToDeposit(depositDataSlotWithCountOffset, currentEntryIndex);
                        _writeTokenAddressToDeposit(
                            depositDataSlotWithCountOffset,
                            YoloV2__TokenType.ERC721,
                            tokenAddress
                        );
                        assembly {
                            sstore(add(depositDataSlotWithCountOffset, DEPOSIT__TOKEN_ID_SLOT_OFFSET), tokenId)
                            roundDepositCount := add(roundDepositCount, 1)
                        }

                        amounts[j] = 1;
                    }

                    batchTransferItems[i].tokenAddress = tokenAddress;
                    batchTransferItems[i].tokenType = TransferManager__TokenType.ERC721;
                    batchTransferItems[i].itemIds = singleDeposit.tokenIdsOrAmounts;
                    batchTransferItems[i].amounts = amounts;
                } else if (singleDeposit.tokenType == YoloV2__TokenType.ERC20) {
                    if (price == 0) {
                        price = erc20Oracle.getTWAP(tokenAddress, uint32(TWAP_DURATION));
                        prices[tokenAddress][roundId] = price;
                    }

                    uint256[] memory amounts = singleDeposit.tokenIdsOrAmounts;
                    if (amounts.length != 1) {
                        revert InvalidLength();
                    }

                    uint256 amount = amounts[0];

                    uint256 entriesCount = ((price * amount) / (10 ** IERC20(tokenAddress).decimals())) /
                        round.valuePerEntry;
                    if (entriesCount == 0) {
                        revert InvalidValue();
                    }

                    batchTransferItems[i].tokenAddress = tokenAddress;
                    batchTransferItems[i].tokenType = TransferManager__TokenType.ERC20;
                    batchTransferItems[i].amounts = singleDeposit.tokenIdsOrAmounts;

                    totalEntriesCount += entriesCount;

                    if (currentEntryIndex != 0) {
                        currentEntryIndex += uint40(entriesCount);
                    } else {
                        currentEntryIndex = _getCurrentEntryIndexWithoutAccrual(round, roundDepositCount, entriesCount);
                    }

                    // round.deposits.push(
                    //     Deposit({
                    //         tokenType: YoloV2__TokenType.ERC20,
                    //         tokenAddress: tokenAddress,
                    //         tokenId: 0,
                    //         tokenAmount: amount,
                    //         depositor: msg.sender,
                    //         withdrawn: false,
                    //         currentEntryIndex: currentEntryIndex
                    //     })
                    // );
                    uint256 depositDataSlotWithCountOffset = _getDepositDataSlotWithCountOffset(
                        roundDepositsLengthSlot,
                        roundDepositCount
                    );
                    _writeDepositorAndCurrentEntryIndexToDeposit(depositDataSlotWithCountOffset, currentEntryIndex);
                    _writeDepositAmountToDeposit(depositDataSlotWithCountOffset, amount);
                    _writeTokenAddressToDeposit(depositDataSlotWithCountOffset, YoloV2__TokenType.ERC20, tokenAddress);
                    unchecked {
                        ++roundDepositCount;
                    }
                } else {
                    revert InvalidTokenType();
                }
            }

            transferManager.transferBatchItemsAcrossCollections(batchTransferItems, msg.sender, address(this));
        }

        if (roundDepositCount > MAXIMUM_NUMBER_OF_DEPOSITS_PER_ROUND) {
            revert MaximumNumberOfDepositsReached();
        }

        assembly {
            sstore(roundDepositsLengthSlot, roundDepositCount)
        }

        {
            uint256 numberOfParticipants = round.numberOfParticipants;

            _validateOnePlayerCannotFillUpTheWholeRound(roundDepositCount, numberOfParticipants);

            if (_shouldDrawWinner(numberOfParticipants, round.maximumNumberOfParticipants, roundDepositCount)) {
                _drawWinner(round, roundId);
            }
        }

        emit Deposited(msg.sender, roundId, totalEntriesCount);
    }

    /**
     * @param roundId The ID of the round to be cancelled.
     */
    function _cancel(uint256 roundId) private {
        Round storage round = rounds[roundId];

        _validateRoundStatus(round, RoundStatus.Open);

        uint256 cutoffTime = round.cutoffTime;
        if (cutoffTime == 0 || block.timestamp < cutoffTime) {
            revert CutoffTimeNotReached();
        }

        if (round.numberOfParticipants > 1) {
            revert RoundCannotBeClosed();
        }

        round.status = RoundStatus.Cancelled;

        emit RoundStatusUpdated(roundId, RoundStatus.Cancelled);

        _startRound({_roundsCount: roundId});
    }

    /**
     * @param requestId The ID of the request
     * @param randomWords The random words returned by Chainlink
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (randomnessRequests[requestId].exists) {
            uint256 roundId = randomnessRequests[requestId].roundId;
            Round storage round = rounds[roundId];

            if (round.status == RoundStatus.Drawing) {
                round.status = RoundStatus.Drawn;
                uint256 randomWord = randomWords[0];
                randomnessRequests[requestId].randomWord = randomWord;

                uint256 count = round.deposits.length;
                uint256[] memory currentEntryIndexArray = new uint256[](count);
                for (uint256 i; i < count; ++i) {
                    currentEntryIndexArray[i] = uint256(round.deposits[i].currentEntryIndex);
                }

                uint256 currentEntryIndex = currentEntryIndexArray[_unsafeSubtract(count, 1)];
                uint256 winningEntry = _unsafeAdd(randomWord % currentEntryIndex, 1);
                round.winner = round.deposits[currentEntryIndexArray.findUpperBound(winningEntry)].depositor;
                round.protocolFeeOwed = (round.valuePerEntry * currentEntryIndex * round.protocolFeeBp) / 10_000;

                emit RoundStatusUpdated(roundId, RoundStatus.Drawn);

                _startRound({_roundsCount: roundId});
            }
        }
    }

    /**
     * @param roundId The round ID.
     * @param round The round.
     */
    function _incrementUserDepositCount(uint256 roundId, Round storage round) private {
        uint256 userDepositCount = depositCount[roundId][msg.sender];
        if (userDepositCount == 0) {
            uint256 numberOfParticipants = round.numberOfParticipants;
            if (numberOfParticipants == round.maximumNumberOfParticipants) {
                revert MaximumNumberOfParticipantsReached();
            }
            unchecked {
                round.numberOfParticipants = uint40(numberOfParticipants + 1);
            }
        }
        unchecked {
            depositCount[roundId][msg.sender] = userDepositCount + 1;
        }
    }

    /**
     * @param round The round to check.
     */
    function _setCutoffTimeIfNotSet(Round storage round) private {
        if (round.cutoffTime == 0) {
            round.cutoffTime = uint40(block.timestamp + roundDuration);
        }
    }

    /**
     * @dev This function is used to write the following values to the round:
     *      - maximumNumberOfParticipants
     *      - valuePerEntry
     *      - protocolFeeBp
     *
     *      roundValue can be provided to write other to other fields in the round.
     * @param roundId The round ID.
     * @param roundValue The starting round slot value to write to the round.
     * @return _maximumNumberOfParticipantsPerRound The round's maximum number of participants per round.
     * @return _protocolFeeBp The round's protocol fee in basis points.
     * @return _valuePerEntry The round's value per entry in ETH.
     */
    function _writeDataToRound(
        uint256 roundId,
        uint256 roundValue
    ) private returns (uint40 _maximumNumberOfParticipantsPerRound, uint16 _protocolFeeBp, uint96 _valuePerEntry) {
        // This is equivalent to
        // round.maximumNumberOfParticipants = maximumNumberOfParticipantsPerRound;
        // round.valuePerEntry = valuePerEntry;
        // round.protocolFeeBp = protocolFeeBp;

        _maximumNumberOfParticipantsPerRound = maximumNumberOfParticipantsPerRound;
        _protocolFeeBp = protocolFeeBp;
        _valuePerEntry = valuePerEntry;

        uint256 roundSlot = _getRoundSlot(roundId);
        assembly {
            roundValue := or(
                roundValue,
                shl(ROUND__MAXIMUM_NUMBER_OF_PARTICIPANTS_OFFSET, _maximumNumberOfParticipantsPerRound)
            )
            roundValue := or(roundValue, shl(ROUND__PROTOCOL_FEE_BP_OFFSET, _protocolFeeBp))

            sstore(roundSlot, roundValue)
            sstore(
                add(roundSlot, ROUND__VALUE_PER_ENTRY_SLOT_OFFSET),
                shl(ROUND__VALUE_PER_ENTRY_OFFSET, _valuePerEntry)
            )
        }
    }

    /**
     * @param depositDataSlotWithCountOffset The deposit data slot with count offset.
     * @param currentEntryIndex The current entry index at the current deposit.
     */
    function _writeDepositorAndCurrentEntryIndexToDeposit(
        uint256 depositDataSlotWithCountOffset,
        uint256 currentEntryIndex
    ) private {
        assembly {
            sstore(
                add(depositDataSlotWithCountOffset, DEPOSIT__LAST_SLOT_OFFSET),
                or(caller(), shl(DEPOSIT__CURRENT_ENTRY_INDEX_OFFSET, currentEntryIndex))
            )
        }
    }

    /**
     * @param depositDataSlotWithCountOffset The deposit data slot with count offset.
     * @param depositAmount The token amount to write to the deposit.
     */
    function _writeDepositAmountToDeposit(uint256 depositDataSlotWithCountOffset, uint256 depositAmount) private {
        assembly {
            sstore(add(depositDataSlotWithCountOffset, DEPOSIT__TOKEN_AMOUNT_SLOT_OFFSET), depositAmount)
        }
    }

    /**
     * @param depositDataSlotWithCountOffset The deposit data slot with count offset.
     * @param tokenType The token type to write to the deposit.
     * @param tokenAddress The token address to write to the deposit.
     */
    function _writeTokenAddressToDeposit(
        uint256 depositDataSlotWithCountOffset,
        YoloV2__TokenType tokenType,
        address tokenAddress
    ) private {
        assembly {
            sstore(depositDataSlotWithCountOffset, or(tokenType, shl(DEPOSIT__TOKEN_ADDRESS_OFFSET, tokenAddress)))
        }
    }

    /**
     * @param round The round to deposit ETH into.
     * @param roundId The round ID.
     * @param roundValuePerEntry The value of each entry in ETH.
     * @param depositAmount The amount of ETH to deposit.
     * @return entriesCount The number of entries for the deposit amount.
     */
    function _depositETH(
        Round storage round,
        uint256 roundId,
        uint256 roundValuePerEntry,
        uint256 depositAmount
    ) private returns (uint256 entriesCount) {
        entriesCount = depositAmount / roundValuePerEntry;
        uint256 roundDepositCount = round.deposits.length;

        _validateOnePlayerCannotFillUpTheWholeRound(_unsafeAdd(roundDepositCount, 1), round.numberOfParticipants);

        uint40 currentEntryIndex = _getCurrentEntryIndexWithoutAccrual(round, roundDepositCount, entriesCount);
        // This is equivalent to
        // round.deposits.push(
        //     Deposit({
        //         tokenType: YoloV2__TokenType.ETH,
        //         tokenAddress: address(0),
        //         tokenId: 0,
        //         tokenAmount: msg.value,
        //         depositor: msg.sender,
        //         withdrawn: false,
        //         currentEntryIndex: currentEntryIndex
        //     })
        // );
        // unchecked {
        //     roundDepositCount += 1;
        // }
        uint256 roundDepositsLengthSlot = _getRoundSlot(roundId) + ROUND__DEPOSITS_LENGTH_SLOT_OFFSET;
        uint256 depositDataSlotWithCountOffset = _getDepositDataSlotWithCountOffset(
            roundDepositsLengthSlot,
            roundDepositCount
        );
        // We don't have to write tokenType, tokenAddress, tokenId, and withdrawn because they are 0.
        _writeDepositorAndCurrentEntryIndexToDeposit(depositDataSlotWithCountOffset, currentEntryIndex);
        _writeDepositAmountToDeposit(depositDataSlotWithCountOffset, depositAmount);
        assembly {
            sstore(roundDepositsLengthSlot, add(roundDepositCount, 1))
        }
    }

    /**
     * @param singleDeposit The deposit to withdraw from.
     * @param transferAccumulator The ERC-20 transfer accumulator so far.
     * @param ethAmount The ETH amount so far.
     * @return The new ETH amount.
     */
    function _transferTokenOut(
        Deposit storage singleDeposit,
        TransferAccumulator memory transferAccumulator,
        uint256 ethAmount
    ) private returns (uint256) {
        _validateDepositNotWithdrawn(singleDeposit);

        singleDeposit.withdrawn = true;

        YoloV2__TokenType tokenType = singleDeposit.tokenType;
        if (tokenType == YoloV2__TokenType.ETH) {
            ethAmount += singleDeposit.tokenAmount;
        } else if (tokenType == YoloV2__TokenType.ERC721) {
            _executeERC721TransferFrom(singleDeposit.tokenAddress, address(this), msg.sender, singleDeposit.tokenId);
        } else if (tokenType == YoloV2__TokenType.ERC20) {
            address tokenAddress = singleDeposit.tokenAddress;
            if (tokenAddress == transferAccumulator.tokenAddress) {
                transferAccumulator.amount += singleDeposit.tokenAmount;
            } else {
                if (transferAccumulator.amount != 0) {
                    _executeERC20DirectTransfer(
                        transferAccumulator.tokenAddress,
                        msg.sender,
                        transferAccumulator.amount
                    );
                }

                transferAccumulator.tokenAddress = tokenAddress;
                transferAccumulator.amount = singleDeposit.tokenAmount;
            }
        }

        return ethAmount;
    }

    function _validateIsOwner() private view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotOwner();
        }
    }

    function _validateIsOperator() private view {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotOperator();
        }
    }

    /**
     * @param round The round to check the status of.
     * @param status The expected status of the round
     */
    function _validateRoundStatus(Round storage round, RoundStatus status) private view {
        if (round.status != status) {
            revert InvalidStatus();
        }
    }

    /**
     * @param round The round to check the status and cutoffTime of.
     */
    function _validateRoundIsOpen(Round storage round) private view {
        if (round.status != RoundStatus.Open || (round.cutoffTime != 0 && block.timestamp >= round.cutoffTime)) {
            revert InvalidStatus();
        }
    }

    /**
     * @param singleDeposit The deposit to withdraw from.
     */
    function _validateDepositNotWithdrawn(Deposit storage singleDeposit) private view {
        if (singleDeposit.withdrawn) {
            revert AlreadyWithdrawn();
        }
    }

    /**
     * @param length The length of the array.
     */
    function _validateArrayLengthIsNotEmpty(uint256 length) private pure {
        if (length == 0) {
            revert InvalidLength();
        }
    }

    function _validateOutflowIsAllowed() private view {
        if (!outflowAllowed) {
            revert OutflowNotAllowed();
        }
    }

    /**
     * @param index The array index.
     * @param round The round to check the deposits array index of.
     */
    function _validateDepositsArrayIndex(uint256 index, Round storage round) private view {
        if (index >= round.deposits.length) {
            revert InvalidIndex();
        }
    }

    /**
     * @param singleDeposit The deposit to check the depositor of.
     */
    function _validateMsgSenderIsDepositor(Deposit storage singleDeposit) private view {
        if (msg.sender != singleDeposit.depositor) {
            revert NotDepositor();
        }
    }

    /**
     * @param round The round to check the winner of.
     */
    function _validateMsgSenderIsWinner(Round storage round) private view {
        if (msg.sender != round.winner) {
            revert NotWinner();
        }
    }

    /**
     * @param roundDepositCount The number of deposits in the round.
     * @param numberOfParticipants The number of participants in the round.
     */
    function _validateOnePlayerCannotFillUpTheWholeRound(
        uint256 roundDepositCount,
        uint256 numberOfParticipants
    ) private pure {
        if (roundDepositCount == MAXIMUM_NUMBER_OF_DEPOSITS_PER_ROUND) {
            if (numberOfParticipants == 1) {
                revert OnePlayerCannotFillUpTheWholeRound();
            }
        }
    }

    /**
     * @param collection The collection address.
     * @param floorPrice The floor price response from Reservoir oracle.
     */
    function _verifyReservoirSignature(address collection, ReservoirOracleFloorPrice calldata floorPrice) private view {
        if (block.timestamp > floorPrice.timestamp + uint256(signatureValidityPeriod)) {
            revert SignatureExpired();
        }

        bytes32 expectedMessageId = keccak256(
            abi.encode(RESERVOIR_ORACLE_ID_TYPEHASH, uint8(1), TWAP_DURATION, collection, false)
        );

        if (expectedMessageId != floorPrice.id) {
            revert MessageIdInvalid();
        }

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        RESERVOIR_ORACLE_MESSAGE_TYPEHASH,
                        expectedMessageId,
                        keccak256(floorPrice.payload),
                        floorPrice.timestamp,
                        block.chainid
                    )
                )
            )
        );

        SignatureCheckerMemory.verify(messageHash, reservoirOracle, floorPrice.signature);
    }

    /**
     * @param singleDeposit The ERC-721 deposit to get the price of.
     * @return price The price decoded from the Reservoir oracle payload.
     */
    function _getReservoirPrice(DepositCalldata calldata singleDeposit) private view returns (uint256 price) {
        address currency;
        ReservoirOracleFloorPrice calldata reservoirOracleFloorPrice = singleDeposit.reservoirOracleFloorPrice;
        _verifyReservoirSignature(singleDeposit.tokenAddress, reservoirOracleFloorPrice);
        (currency, price) = abi.decode(reservoirOracleFloorPrice.payload, (address, uint256));
        if (currency != address(0)) {
            revert InvalidCurrency();
        }
    }

    /**
     * @param round The open round.
     * @param roundDepositCount The number of deposits in the round.
     * @param entriesCount The number of entries to be added.
     * @return currentEntryIndex The current entry index after adding entries count.
     */
    function _getCurrentEntryIndexWithoutAccrual(
        Round storage round,
        uint256 roundDepositCount,
        uint256 entriesCount
    ) private view returns (uint40 currentEntryIndex) {
        if (roundDepositCount == 0) {
            currentEntryIndex = uint40(entriesCount);
        } else {
            currentEntryIndex = uint40(
                round.deposits[_unsafeSubtract(roundDepositCount, 1)].currentEntryIndex + entriesCount
            );
        }
    }

    /**
     * @param protocolFeeOwedInETH The protocol fee owed in ETH.
     * @return protocolFeeOwedInLOOKS The protocol fee owed in LOOKS.
     */
    function _protocolFeeOwedInLOOKS(
        uint256 protocolFeeOwedInETH
    ) private view returns (uint256 protocolFeeOwedInLOOKS) {
        protocolFeeOwedInLOOKS =
            (1e18 * protocolFeeOwedInETH * protocolFeeDiscountBp) /
            erc20Oracle.getTWAP(LOOKS, uint32(TWAP_DURATION)) /
            10_000;
    }

    /**
     * @param roundId The round ID.
     * @return roundSlot The round's starting storage slot.
     */
    function _getRoundSlot(uint256 roundId) private pure returns (uint256 roundSlot) {
        assembly {
            mstore(0x00, roundId)
            mstore(0x20, rounds.slot)
            roundSlot := keccak256(0x00, 0x40)
        }
    }

    /**
     * @param roundDepositsLengthSlot The round's deposits length slot.
     * @param roundDepositCount The number of deposits in the round.
     * @return depositDataSlotWithCountOffset The round's next deposit's starting storage slot.
     */
    function _getDepositDataSlotWithCountOffset(
        uint256 roundDepositsLengthSlot,
        uint256 roundDepositCount
    ) private pure returns (uint256 depositDataSlotWithCountOffset) {
        assembly {
            mstore(0x00, roundDepositsLengthSlot)
            let depositsDataSlot := keccak256(0x00, 0x20)
            depositDataSlotWithCountOffset := add(depositsDataSlot, mul(DEPOSIT__OCCUPIED_SLOTS, roundDepositCount))
        }
    }

    /**
     * @param numberOfParticipants The number of participants in the round.
     * @param maximumNumberOfParticipants The maximum number of participants in the round.
     * @param roundDepositCount The number of deposits in the round.
     */
    function _shouldDrawWinner(
        uint256 numberOfParticipants,
        uint256 maximumNumberOfParticipants,
        uint256 roundDepositCount
    ) private pure returns (bool shouldDraw) {
        shouldDraw =
            numberOfParticipants == maximumNumberOfParticipants ||
            (numberOfParticipants > 1 && roundDepositCount == MAXIMUM_NUMBER_OF_DEPOSITS_PER_ROUND);
    }

    /**
     * Unsafe math functions.
     */

    function _unsafeAdd(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return a + b;
        }
    }

    function _unsafeSubtract(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            return a - b;
        }
    }
}
