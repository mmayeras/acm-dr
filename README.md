# ACM hub disaster recovery lab

*Acronyms: ACM = Advanced Cluster Management.*

> **▶ [Watch the animated flow diagram](https://mmayeras.fr/acm-dr/flow/)**: the whole story in 7
> short animations. Then come back here to pick your scenario.

## The idea in one minute

*Acronyms: ACM = Advanced Cluster Management.*

- A **hub** is the cluster that runs ACM. It manages other clusters,
  called **spokes** (managed clusters).
- If the hub disappears, the spokes keep running, but nobody manages them anymore.
- So the hub **backs itself up** every hour into a bucket (object storage).
- A **second hub** can read that bucket and rebuild the same setup.

```
   HUB1 (today's hub) ──backup──▶  bucket  ──restore──▶  HUB2 (new hub)
          │                                                  ┊
          └──────────── manages ──▶  SPOKE  ◀┄┄ may manage later
```

The lab names: **HUB1** is the existing hub, **HUB2** the new one, **SPOKE** one managed cluster.

## Two ways to use the backup

|  | **Passive** | **Active** |
|---|---|---|
| What HUB2 gets | HUB1's setup: policies, placements, credentials | HUB1's setup **and** the clusters |
| Who manages the spoke | still HUB1 | HUB2 |
| Think of it as | a spare hub, ready but idle | moving house |
| Diagram flows | [2 (one-shot) and 3 (continuous)](https://mmayeras.fr/acm-dr/flow/) | [4, 5 and 6](https://mmayeras.fr/acm-dr/flow/) |
| Lab modules | [5a](labs/05a-passive-restore.md) | [4](labs/04-prepare-primary.md) and [5](labs/05-restore-new-hub.md) |

**Passive** comes in two flavours:

- **One-shot:** a photo of HUB1 at one moment. Run it again to refresh.
- **Continuous:** HUB2 keeps copying each new HUB1 backup (every 10 minutes here). A warm spare.

**Active** is one switch in the restore: "bring the clusters too". You can flip it on a fresh HUB2
(flow 5) or later, on a passive HUB2 (flow 6). Before that, HUB1 must stop backing up and agree to
let its clusters go (flow 4).

## How a spoke changes hub (the only tricky part)

Each spoke runs an agent, the **klusterlet**. The klusterlet reads its hub's address from a secret on
the spoke (`bootstrap-hub-kubeconfig`). Today that address is HUB1.

Moving the spoke means writing HUB2's address into that secret. It happens in three steps:

1. **Before the backup:** HUB1 creates an account on each spoke and keeps its password (a token). That
   account can edit that one secret and nothing else. The token goes into the backup.
2. **During the restore:** HUB2 finds the token in the backup, logs in to the spoke with it, and
   writes HUB2's address into the secret.
3. **After:** the klusterlet sees the new address and connects to HUB2.

(In the product, that account is called a ManagedServiceAccount, turned on by
`useManagedServiceAccount: true` in the backup schedule.)

**When it goes wrong.** The move fails in two cases:

1. The backup has no token for that spoke (for example, it was taken before the token existed).
2. HUB2 has the token but cannot reach the spoke over the network to write its address.

In both cases the spoke keeps talking to HUB1, and HUB2 shows it as `Pending Import` (known, but never
connected). Diagram flow 7 shows this, and [troubleshooting](labs/09-troubleshooting.md) explains
how to fix it.

Full explanation: [REFERENCE.md](REFERENCE.md#how-imported-clusters-move-managedserviceaccount-msa).

## Do the lab

*Acronyms: ACM = Advanced Cluster Management.*

| Step | Module | Passive | Active |
|---|---|:---:|:---:|
| Set up your laptop and check the clusters | [0 - Prerequisites](labs/00-prereqs.md) | ✓ | ✓ |
| Create test data on HUB1 | [1 - Baseline](labs/01-baseline-seed.md) | ✓ | ✓ |
| Turn on backups on HUB1 | [2 - Enable backup](labs/02-enable-backup-hub1.md) | ✓ | ✓ |
| Install ACM on HUB2 | [3 - New hub](labs/03-install-new-hub.md) | ✓ | ✓ |
| Copy HUB1's setup, no clusters | [5a - Passive restore](labs/05a-passive-restore.md) | ✓ | |
| Freeze HUB1, let the clusters go | [4 - Prepare HUB1](labs/04-prepare-primary.md) | | ✓ |
| Restore with the clusters | [5 - Restore](labs/05-restore-new-hub.md) | | ✓ |
| Check the result | [6 - Validate](labs/06-validate.md) | step 2 | ✓ |
| Tidy up | [7 - Clean up](labs/07-cleanup-primary.md) | ✓ | ✓ |
| Move everything back (optional) | [8 - Fail back](labs/08-failback.md) | | ✓ |
| When something is stuck | [9 - Troubleshooting](labs/09-troubleshooting.md) | ✓ | ✓ |

Each module ends with a **checkpoint**: do not move on until it passes.

## What you need

*Acronyms: ACM = Advanced Cluster Management, S3 = Amazon Simple Storage Service (object storage protocol).*

- HUB1: an existing ACM 2.17 hub with at least one managed cluster.
- HUB2: a new, empty OpenShift cluster (a single node is enough), at least as big as HUB1.
- A bucket both hubs can reach (any storage speaking the S3 protocol).
- For the active scenario: HUB2 and the spoke must reach each other on port `6443`, both ways.

Details: [module 0](labs/00-prereqs.md).

## Where things are

- [`labs/`](https://github.com/mmayeras/acm-dr/tree/main/labs): the guided modules, with every command and expected output.
- [`manifests/`](https://github.com/mmayeras/acm-dr/tree/main/manifests): the backup and restore objects, every field commented.
- [`REFERENCE.md`](REFERENCE.md): the details: topology, network, backup groups, restore fields.
- [Animated flow diagram](https://mmayeras.fr/acm-dr/flow/) and the
  [blog article](https://mmayeras.fr/acm-hub-dr/).
- Source: [github.com/mmayeras/acm-dr](https://github.com/mmayeras/acm-dr). Product procedure:
  [Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/business_continuity/index#keep-hub-active-restore).
