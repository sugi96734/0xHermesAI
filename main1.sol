// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title 0xHermesAI — Winged messenger duel ledger; claw-compatible challenge slots and on-chain leaderboard.
/// @notice Vanguard seed binds resolution entropy to chain; seasons and rank snapshots are immutable once sealed.
contract HermesAI {
    /// @dev Fixed-point scale for win rate and percentages.
    uint256 public constant WAD = 1e18;
    uint256 public constant REWARD_BP = 850;
    uint256 public constant BP_DENOM = 10_000;
    uint256 public constant MAX_CHALLENGES_PER_BOT = 32;
    uint256 public constant MAX_ACTIVE_DUELS = 256;
    uint256 public constant DUEL_TIMEOUT_BLOCKS = 7200;
    uint256 public constant SEASON_DURATION_BLOCKS = 201600;
    uint256 public constant MIN_STAKE = 0.001 ether;
    uint256 public constant ENTRY_FEE = 0.0001 ether;

    bytes32 public constant HERMES_VANGUARD_SEED = 0x0b3c5d7f9a1e4c6a8b0d2e4f6a8c0e2b4d6f8a0a2c4e6f8b0d2e4a6c8e0f2b4d6;

    address public immutable controller;
    address public immutable treasury;
    address public immutable referee;
    address public immutable rewardVault;
    address public immutable resolutionOracle;

    struct BotProfile {
        bytes32 handleHash;
        uint256 totalWins;
        uint256 totalLosses;
        uint256 totalDraws;
        uint256 rankPoints;
        uint256 registeredAtBlock;
        bool active;
    }

    struct DuelSlot {
        address challenger;
        address defender;
        uint256 stakeAmount;
        uint256 issuedAtBlock;
        uint256 acceptedAtBlock;
        uint8 status; // 0 open, 1 accepted, 2 resolved, 3 cancelled, 4 timeout
        bytes32 resolutionHash;
        address winner; // zero if draw
    }

    struct SeasonMeta {
        uint256 startBlock;
        uint256 endBlock;
        uint256 totalDuels;
        bytes32 leaderboardRoot;
        bool sealed;
    }

    struct LeaderboardEntry {
        address bot;
        uint256 rankPoints;
        uint256 wins;
        uint256 losses;
        uint256 draws;
    }

    mapping(address => BotProfile) public botProfile;
    mapping(uint256 => DuelSlot) public duelSlot;
    mapping(uint256 => SeasonMeta) public seasonMeta;
    mapping(address => uint256) public activeDuelCount;
    mapping(address => uint256[]) public duelsByChallenger;
    mapping(address => uint256[]) public duelsByDefender;
    mapping(uint256 => address[]) public seasonTopBots;
    uint256 public nextDuelId;
    uint256 public currentSeasonId;
    uint256 public totalStakeHeld;
    uint256 public totalFeesCollected;
    uint256 public totalBotsRegisteredCount;
    bool public paused;
    uint256 private _reentrancyLock;

    error Hermes_NotController();
    error Hermes_NotReferee();
    error Hermes_NotOracle();
    error Hermes_WhenPaused();
    error Hermes_BotNotRegistered();
    error Hermes_BotAlreadyRegistered();
    error Hermes_InvalidHandle();
    error Hermes_ChallengeLimitReached();
    error Hermes_DuelNotFound();
    error Hermes_DuelNotOpen();
    error Hermes_DuelNotAccepted();
    error Hermes_DuelAlreadyResolved();
    error Hermes_CannotChallengeSelf();
    error Hermes_InsufficientStake();
    error Hermes_ZeroAddress();
    error Hermes_Reentrancy();
    error Hermes_InvalidSeason();
    error Hermes_SeasonNotEnded();
    error Hermes_SeasonAlreadySealed();
    error Hermes_InvalidResolution();
    error Hermes_TransferFailed();
    error Hermes_TimeoutNotReached();
    error Hermes_EntryFeeRequired();
    error Hermes_NotDefender();

    event BotRegistered(address indexed bot, bytes32 handleHash, uint256 atBlock);
    event DuelProposed(uint256 indexed duelId, address challenger, address defender, uint256 stake, uint256 atBlock);
    event DuelAccepted(uint256 indexed duelId, uint256 acceptedAtBlock);
    event DuelResolved(uint256 indexed duelId, address winner, bytes32 resolutionHash, uint256 atBlock);
    event DuelCancelled(uint256 indexed duelId, uint256 atBlock);
    event DuelTimedOut(uint256 indexed duelId, uint256 atBlock);
    event SeasonStarted(uint256 indexed seasonId, uint256 startBlock, uint256 endBlock);
    event SeasonSealed(uint256 indexed seasonId, bytes32 leaderboardRoot);
    event LeaderboardSnapshot(uint256 indexed seasonId, address[] topBots);
    event PauseToggled(bool paused);
    event RewardClaimed(address indexed bot, uint256 amount);
    event StakeWithdrawn(address indexed bot, uint256 amount);

    constructor() {
        controller = address(0x0b3c5d7F9a1E4c6A8b0D2e4F6a8C0e2B4d6F8a0A2);
        treasury = address(0x0c4d6e8F0a2B4c6D8e0F2a4B6c8D0e2F4a6B8c0B4);
        referee = address(0x0d5e7f9A1b3C5d7E9f1A3b5C7d9E1f3A5b7C9d1C6);
        rewardVault = address(0x0e6f8a0B2c4D6e8F0a2B4c6D8e0F2a4B6c8D0e2D8);
        resolutionOracle = address(0x0f7a9b1C3d5E7f9A1b3C5d7E9f1A3b5C7d9E1f3E0);

        currentSeasonId = 1;
        seasonMeta[1] = SeasonMeta({
            startBlock: block.number,
            endBlock: block.number + SEASON_DURATION_BLOCKS,
            totalDuels: 0,
            leaderboardRoot: bytes32(0),
            sealed: false
        });
        emit SeasonStarted(1, block.number, block.number + SEASON_DURATION_BLOCKS);
    }

    modifier onlyController() {
        if (msg.sender != controller) revert Hermes_NotController();
        _;
    }

    modifier onlyReferee() {
        if (msg.sender != referee) revert Hermes_NotReferee();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != resolutionOracle) revert Hermes_NotOracle();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Hermes_WhenPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert Hermes_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    function setPaused(bool _paused) external onlyController {
        paused = _paused;
        emit PauseToggled(paused);
    }

    function registerBot(bytes32 handleHash) external payable whenNotPaused nonReentrant {
        if (msg.sender == address(0)) revert Hermes_ZeroAddress();
        if (handleHash == bytes32(0)) revert Hermes_InvalidHandle();
        if (botProfile[msg.sender].registeredAtBlock != 0) revert Hermes_BotAlreadyRegistered();
        if (msg.value < ENTRY_FEE) revert Hermes_EntryFeeRequired();

        totalFeesCollected += ENTRY_FEE;
        if (msg.value > ENTRY_FEE) {
            (bool ok,) = msg.sender.call{ value: msg.value - ENTRY_FEE }("");
            if (!ok) revert Hermes_TransferFailed();
        }

        totalBotsRegisteredCount++;
        botProfile[msg.sender] = BotProfile({
            handleHash: handleHash,
            totalWins: 0,
            totalLosses: 0,
            totalDraws: 0,
            rankPoints: 0,
            registeredAtBlock: block.number,
            active: true
        });
        emit BotRegistered(msg.sender, handleHash, block.number);
    }

    function proposeDuel(address defender, bytes32 nonceHash) external payable whenNotPaused nonReentrant returns (uint256 duelId) {
        if (defender == address(0) || defender == msg.sender) revert Hermes_CannotChallengeSelf();
