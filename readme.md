# 🛡️ Inzo: AI-Powered Decentralized Insurance Core Contracts

**Inzo is pioneering the future of insurance by integrating intelligent AI agents with transparent, efficient, and secure smart contracts on Polkadot's AssetHub, powered by PolkaVM.**

This repository contains the core Solidity smart contracts that form the on-chain backbone of the Inzo insurance platform. Our vision is to make insurance more accessible, fair, and automated.

## 🚀 The Inzo Vision: Problem & Solution

Traditional insurance is often plagued by slow manual processes, opaque decision-making, high operational costs, and frustrating user experiences, especially during onboarding and claims.

**Inzo solves this by:**

1.  ✨ **Intelligent Automation:** Off-chain AI agents (envisioned with ElizaOS) handle complex tasks like KYC verification and initial claim assessment, providing speed and data-driven insights.
2.  ⛓️ **On-Chain Trust & Transparency:** Solidity smart contracts deployed on Westend Asset Hub (PolkaVM) manage policies as NFTs, enforce rules immutably, and automate financial operations.
3.  👤 **User-Centric Experience:** Interactions are streamlined via familiar interfaces like Telegram/Discord bots, abstracting blockchain complexity.

This hybrid approach combines the best of AI's analytical power with blockchain's security and verifiability.

## Core Architectural Principles

The Inzo protocol is designed as a modular system of interacting smart contracts. This promotes separation of concerns, upgradability (via future proxy patterns), and clarity. The primary interaction flow is orchestrated by off-chain AI agents and relayers, with the smart contracts serving as the immutable ledger and rule enforcers.

## Deployed Contract Addresses (Westend AssetHub)

*   **`PolicyNFT.sol`:** `0xb8C797C5E7f3EFB170420AB5d4149bDF31C76fC3`
*   **`PolicyLogicContract.sol`:** `0xB27B1aE498D25A1E42417EFd34C361Ce563e40dd`
*   **`ClaimProcessorContract.sol`:** `0x1f71F422C8660045956E1c0D3E6C0b9C12fCFADc`
*   **`TreasuryContract.sol`:** `0xB6A6128a904C4110a5E78980C0D5846B3303649a`
*   **Admin/Oracle/Deployer Address (for MVP functionality):** `0xeb10E960092F0B8FeDB5c8D64D726d602D089D18`

## Contract Details & Interactions

### 1. `PolicyNFT.sol`

*   **Purpose:** Implements the ERC721 standard to represent each insurance policy as a unique, ownable Non-Fungible Token. It serves as the definitive record of policy ownership and links to policy metadata.
*   **Key State Variables:**
    *   `_name`, `_symbol`: Standard ERC721 metadata.
    *   `_owners`: Mapping `tokenId` to owner address.
    *   `_balances`: Mapping owner address to token count.
    *   `_tokenApprovals`, `_operatorApprovals`: Standard ERC721 approval mechanisms.
    *   `_tokenURIs`: Mapping `tokenId` to metadata URI (e.g., IPFS link).
    *   `_nextTokenId`: Counter for generating unique token IDs.
    *   `policyManagerContract`: The address of `PolicyLogicContract.sol`, exclusively authorized to mint new policy NFTs and update URIs.
*   **Key Functions:**
    *   `constructor(name, symbol, initialPolicyManager)`: Initializes the NFT.
    *   `mintPolicyNFT(recipient, uri) external onlyPolicyManager returns (uint256)`: Mints a new policy NFT. Called by `PolicyLogicContract`.
    *   `burnPolicyNFT(tokenId) external`: Allows owner or `policyManagerContract` to burn an NFT.
    *   `updateTokenURI(tokenId, newUri) external onlyPolicyManager`: Allows `policyManagerContract` to update metadata.
    *   Standard ERC721 view functions: `balanceOf`, `ownerOf`, `tokenURI`, `getApproved`, `isApprovedForAll`.
    *   Standard ERC721 transfer functions: `transferFrom`, `safeTransferFrom`, `approve`, `setApprovalForAll`.
*   **Interaction:** Primarily acts as a service contract for `PolicyLogicContract`.

### 2. `PolicyLogicContract.sol`

*   **Purpose:** Orchestrates the lifecycle of insurance policies, from creation based on KYC and initial premium payment to managing active statuses and initiating claims.
*   **Key State Variables:**
    *   `admin`: For administrative functions.
    *   `policyNFTContract`: Interface to the deployed `PolicyNFT` contract.
    *   `kycRegistryContract`: Interface to a (potentially simplified or mocked) KYC contract/oracle. For MVP, this holds a simple `mapping(address => bool) public kycVerifiedUsers;` and uses an oracle address for updates.
    *   `treasuryContract`: Interface to the `TreasuryContract`.
    *   `claimProcessorContractAddress`: Address of the `ClaimProcessorContract`.
    *   `policyDetails`: Mapping `policyNFTId` to a `PolicyData` struct.
    *   `PolicyData` struct: Contains `originalOwner`, `policyNFTId`, `deviceIdentifier`, `coverageAmount`, `premiumAmount`, `premiumIntervalSeconds`, `lastPremiumPaidTimestamp`, `policyEndDate`, `status` (enum `PolicyStatus`), `termsHash`, `evidenceBundleHash`.
*   **Key Functions:**
    *   `constructor(policyNFTAddr, kycRegistryAddr, treasuryAddr)`: Sets dependent contract addresses.
    *   `setKYCStatus(user, isVerified) external onlyKycOracle`: Updates user KYC status (if KYC logic is internal).
    *   `createPolicy(...) external payable returns (policyNFTId)`:
        *   Requires `kycRegistryContract.isUserKYCVerified(policyHolder)`.
        *   Requires `msg.value == premiumAmount`.
        *   Calls `policyNFTContract.mintPolicyNFT(policyHolder, nftMetadataURI)`.
        *   Stores `PolicyData` struct.
        *   Calls `treasuryContract.depositPremium{value: msg.value}(...)`.
    *   `recordPremiumPayment(policyNFTId) external payable onlyPolicyNFTOwner`:
        *   Validates policy status and `msg.value`.
        *   Updates `lastPremiumPaidTimestamp` and policy `status`.
        *   Calls `treasuryContract.depositPremium{value: msg.value}(...)`.
    *   `checkAndUpdatePolicyStatus(policyNFTId) external`: Allows time-based status updates (e.g., to `LAPSED` or `EXPIRED`).
    *   `initiateClaimFiling(policyNFTId, description, evidenceLinks, requestedAmount) external onlyPolicyNFTOwner returns (internalClaimId)`:
        *   Validates policy status and requested amount.
        *   Sets policy status to `CLAIM_ACTIVE`.
        *   Generates a unique `internalClaimId` and `evidenceHash`.
        *   Emits `ClaimForwardedToProcessor(policyNFTId, claimant, internalClaimId, evidenceHash)`. The off-chain relayer listens to this and calls `ClaimProcessorContract.registerClaimForProcessing()`.
    *   `updatePolicyStatusAfterClaim(policyNFTId, newStatus) external onlyClaimProcessor`: Called by `ClaimProcessorContract` to finalize policy status post-claim.
*   **Interaction:** Calls `PolicyNFT` to mint. Calls `TreasuryContract` to deposit premiums. Is called by `ClaimProcessorContract` to update final policy status. Relies on an external KYC oracle/contract.

### 3. `ClaimProcessorContract.sol`

*   **Purpose:** Manages the detailed claim assessment process. Receives data from off-chain AI/human oracles and applies an internal rules engine to determine claim outcomes. Authorizes payouts.
*   **Key State Variables:**
    *   `admin`, `policyLogicContract`, `treasuryContract`, `aiOracleAddress`, `humanReviewerOracleAddress`.
    *   `claims`: Mapping `claimProcessorId` to a `ClaimDetails` struct.
    *   `ClaimDetails` struct: Contains `originalPolicyNFTId`, `claimant`, `incidentDescriptionHash`, `evidenceBundleHash`, `requestedAmount`, `assessedPayoutAmount`, `assessmentReportHash`, `status` (enum `ClaimProcessingStatus`), timestamps, `aiConfidenceScore`, `fraudRiskDetectedByAI`.
*   **Key Functions:**
    *   `constructor(policyLogicAddr, treasuryAddr, aiOracleAddr, humanReviewerAddr)`: Sets dependencies.
    *   `registerClaimForProcessing(...) external onlyAIOracle returns (claimProcessorId)`: Called by relayer after `PolicyLogicContract` emits `ClaimForwardedToProcessor`. Creates the initial claim record in this contract.
    *   `submitAIAssessment(claimProcessorId, aiRecommendedPayout, confidenceScore, fraudRiskDetected, aiReportHash) external onlyAIOracle`:
        *   Updates claim with AI's findings.
        *   Calls internal `_processAssessmentRules(claimProcessorId)`.
    *   `_processAssessmentRules(claimProcessorId) internal`: **(PolkaVM Showcase)** This function contains the core decision logic. It can be more complex on PolkaVM, evaluating multiple factors (confidence, fraud risk, payout vs. coverage, claim history patterns if available) to determine the next `ClaimProcessingStatus` (e.g., `AI_APPROVED_LOW_RISK`, `AI_APPROVED_NEEDS_REVIEW`, `AI_REJECTED_NEEDS_REVIEW`).
    *   `requestAIClarification(claimProcessorId, reasonHash) external onlyAIOracle`: Allows AI to signal need for more user info.
    *   `submitHumanReview(...) external onlyHumanReviewerOracle`: Updates claim based on human override/review.
    *   `authorizeAndProcessPayout(claimProcessorId) external`:
        *   Requires appropriate approved status.
        *   Calls `treasuryContract.processPayout(claimant, assessedPayoutAmount)`.
        *   Calls `policyLogicContract.updatePolicyStatusAfterClaim(...)` to set policy to `PAID_OUT`.
    *   `finalizeRejectedClaim(claimProcessorId) external`: Closes a rejected claim and updates policy status on `PolicyLogicContract`.
*   **Interaction:** Called by AI/Human oracles (via relayer). Calls `TreasuryContract` for payouts. Calls `PolicyLogicContract` to update final policy status. Reads policy data from `PolicyLogicContract` via `getPolicyData()`.

### 4. `TreasuryContract.sol`

*   **Purpose:** A simple contract to hold pooled premiums and dispense payouts.
*   **Key State Variables:** `admin`, `policyLogicContractAddress`, `claimProcessorContractAddress`.
*   **Key Functions:**
    *   `constructor(initialPolicyLogic, initialClaimProcessor)`: Sets authorized callers.
    *   `depositPremium(payer, policyId, amount) external payable onlyPolicyLogicContract`: Receives funds.
    *   `processPayout(recipient, amount, claimId) external onlyClaimProcessorContract`: Sends funds if balance allows.
    *   `adminWithdrawExcess(...) external onlyAdmin`.
    *   `receive() external payable {}`.
*   **Interaction:** Called by `PolicyLogicContract` to receive premiums. Called by `ClaimProcessorContract` to make payouts.
