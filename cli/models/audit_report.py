from typing import List, Literal

from pydantic import BaseModel


class VulnerabilityDetails(BaseModel):
    function_name: str
    description: str


class AuditReport(BaseModel):
    summary: str
    severity: Literal["high", "medium", "low"]
    vulnerability_details: VulnerabilityDetails
    code_snippet: List[str] = []
    recommendation: str

    def __init__(self, **data):
        data["severity"] = data.get("severity", "").lower()
        if data["severity"] not in ["high", "medium", "low"]:
            data["severity"] = "high"
        super().__init__(**data)


class AuditReportV2(BaseModel):
    tag: List[
        Literal[
            "DAO",
            "DoS",
            "Flashloan",
            "Oracle",
            "Logic error",
            "Reentrancy",
            "Access Control",
            "Liquidation",
            "Slippage",
            "ERC4626",
            "Input Validation",
            "Bad Randomness",
            "Chainlink",
            "Arithmetic",
            "Re-org Attack",
            "Pause",
            "Accounting Error",
            "MEV",
            "Upgradeable",
            "ERC20",
            "call / delegatecall",
            "Uniswap",
            "Cross-Chain",
            "ERC777",
            "Governance",
            "Multisig",
            "Rebalance",
            "ERC1155",
            "XSS Attack",
            "ERC721",
            "Gnosis safe",
            "Opensea",
            "EIP712",
            "Bridge",
            "Zksync",
            "Replay Attack",
            "Solmate",
            "Compound",
            "Solidity Version",
            "EIP4494",
        ]
    ]
    subtag: List[
        Literal[
            "Violating CEI / Missing nonReentrant",
            "Missing Approval",
            "Inflation Attack",
            "Not EIP Compliant",
            "Asset Theft",
            "Rounding Error",
            "Invalid Validation",
            "Cannot partial liquidations",
            "Liquidation – Dust repay / front run evade liquidation",
            "onERC721Received callback",
            "Price Manipulation / Arbitrage opportunity",
            "Bypass Mechanism",
            "Invariant Violation",
            "Does not match with Doc / Implementation Error",
            "Invalid Slippage Control / Missing slippage check",
            "No Incentive to Liquidate",
            "Hardcoded Parameter",
            "minOut set to 0",
            "Missing deadline",
            "Self liquidation",
            "Missing minOut / maxAmount",
            "Deprecated Library",
            "Out of Gas",
            "Stale Value",
            "Front Run",
            "Reward Manipulation",
            "Token Decimal",
            "Incorrect Parameter",
            "No Recovery Mechanism",
            "Centralization Risk",
            "Precision Loss",
            "Scaling",
            "Peg / Depeg",
            "State Update Inconsistency",
            "Duplicate Value",
            "Arbitrary Add/Remove/Set/ Call",
            "Storage Gap",
            "Missing Return Check",
            "Misuse of Dependency",
            "Role Takeover",
            "Missing Time Constraint",
            "Unauthorized Upgrade",
            "Missing Initialization",
            "slot0",
            "Bad Condition",
            "Unfair Liquidation",
            "Nonce",
            "Fee On Transfer Token",
            "payable / receive()",
            "Rebase Token",
            "Whale",
            "ERC777 Callback",
            "EVM Compatibility",
            "Case Sensitive",
            "Execution Order Dependency",
            "Cross-Function Reentrancy",
            "Missing Functionality",
            "Refund Failed",
            "Diamond",
            "Cannot Revoke",
            "Typo",
            "safeApprove",
            "Missing Upper/Lower Bound Check",
            "Unsafe Downcast",
            "1/64 Gas Rule",
            "Block Time / Block Number",
            "Incorrect Formula",
        ]
    ]
    severity: Literal["high", "medium", "low"]
    description: str
    code_snippet: str

    def __init__(self, **data):
        data["severity"] = data.get("severity", "").lower()
        if data["severity"] not in ["high", "medium", "low"]:
            data["severity"] = "high"
        super().__init__(**data)
