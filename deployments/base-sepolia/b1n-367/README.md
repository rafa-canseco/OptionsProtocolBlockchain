# B1N-367 Base Sepolia deployment

- Network: Base Sepolia (`84532`)
- Source commit: `3d6366d2d60c8575f5ecec977cb8923c65ff16f8`
- Approved-inputs SHA-256: `c5dfcea1e36bb62420d9b6e10c2262fa1c50d44f6a1fb6e6e92690a27edb672a`
- Fair-NAV valuator: `0x63aB18b546d2b7a6e9e68eF7C784Ecfa41B76798`
- Deployment transaction: `0x7e6a3206fc39cad7eb4efd042965f4749a0145fbfcaf4f745c46d53f8cea1ede`
- Deployment block: `44662160`
- Atomic rebind transaction: `0xdaa7171cdc74bca1cd16100ddcfa351107f52f44c58b75ee4c4d4e8e126e0df3`
- Activation block: `44662180`
- Explorer: <https://base-sepolia.blockscout.com/address/0x63ab18b546d2b7a6e9e68ef7c784ecfa41b76798>
- Source verification: `Pass - Verified`

The rebind changed the accounting component and the existing strategy config in one
`AccessManager.multicall`. It preserved the active strategy, the deposit-pause flag
(`false`), the allocator pause nonce, the 8,000 bps allocation limit, and the
800 USDC absolute collateral cap. It did not upgrade or reconfigure the CSP adapter.

Post-deployment policy anchors:

```text
interfaceVersion                 1
valuationPolicyVersion           2
requiredModelVersion             1
maxObservationDivergenceBps    500
liabilityBufferBps               0
observationQuorum                2
```
