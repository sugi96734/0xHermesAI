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
