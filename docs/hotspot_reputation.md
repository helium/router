# Hotspot Reputation

The Hotspot reputation tracking provides the ability to minimize the number of Hotspots that do not deliver packets after buying offer.

## Config

- By default the Hotspot Reputation is **disabled**, to enable set env variablable `ROUTER_HOTSPOT_REPUTATION_ENABLED=true` in your `.env`.
- Reputation Threshold can be set via `ROUTER_HOTSPOT_REPUTATION_THRESHOLD=50` default: `50`.

Note: Reputations are only tracked in memory and will be reset upon restart.

## Usage

### CLI

- `router hotspot_rep ls` Display all hotspots' reputation
- `router hotspot_rep <b58_hotspot_id>` Display a hotspot's reputation
- `router hotspot_rep reset <b58_hotspot_id>` Reset hotspot's reputation to 0

Note: Reputation score is based on how many packets were **NOT** delivered.
