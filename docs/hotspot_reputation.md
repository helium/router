# Hotspot Reputation

The Hotspot reputation tracking allow to deny hotspot that do not deliver packet after buying offer.

## Config

- By default the Hotspot Reputation is **disabled**, to enable set env variablable `ROUTER_HOTSPOT_REPUTATION_ENABLED=true` in your `.env`.
- Deny Threshold can set via `ROUTER_HOTSPOT_REPUTATION_THRESHOLD=10` it defaults to `10`.

Note: Reputations are only tracked in memory and will reset on restart.

## Usage

### CLI

- `router hotspot_reputation ls` Display all hotspots' reputation
- `router hotspot_reputation <b58_hotspot_id>` Display a hotspot's reputation
- `router hotspot_reputation reset <b58_hotspot_id>` Reset hotspot's reputation to 0

Note: Reputation score is based on how many packets were **NOT** delivered.