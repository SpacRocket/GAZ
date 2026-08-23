# Cloud layout (AWS)

The application code does not change between local and cloud. What changes is
where `GAZ_HDB`, `GAZ_WDB` and `GAZ_TPLOG` point. This file records why they
point where they do.

## Storage

| Data | Store | Why |
|---|---|---|
| HDB | **FSx for OpenZFS**, NFS | mmap'd, shared by every reader; snapshots and CoW clones give each developer a *writable* copy |
| WDB staging | Local NVMe or EBS gp3 | many small intraday writes, discardable after EOD |
| Tickerplant log | **EBS io2 / gp3** | see below |
| Backups | **S3**, via AWS Backup or an EOD export | off-filesystem copy; the filesystem is not the last line of defence |
| Process logs | EBS + CloudWatch agent | |

### Why OpenZFS

The HDB needs to be one thing that many processes read. Any shared filesystem
does that. OpenZFS is chosen for what it does *besides* that:

- **Copy-on-write clones.** `CreateVolume` with an `OriginSnapshot` and
  `CopyStrategy: CLONE` produces a new volume that shares blocks with its
  parent — near-instant, and it only consumes space for what diverges.
- **The clone is writable.** This is the point. Under a read-only shared mount,
  nobody can exercise the WDB → sort → HDB promotion path, which is the most
  intricate part of the stack. With a clone per developer, they can — against
  real data, without touching production.

Snapshot after each EOD roll; clone per developer; delete the clone when the
branch is done. Keep the HDB on its own volume, since snapshots and clones are
per-volume.

Multi-AZ deployment is available and gives automatic failover. Single-AZ is
fine to start — this is a recovery-time question, not a data-loss one, provided
the backups below actually exist.

### The tickerplant log stays off the shared filesystem

Every tick is appended and `fsync`'d to the tp log — it is the recovery source
for the RDB and WDB. Putting it on NFS means:

- Each write pays a network round trip; under burst, tp publish latency spikes
  and back-pressures the feed handlers.
- The recovery log would share a failure domain with the HDB — a correlated
  failure of the two things that must never fail together. This holds even with
  Multi-AZ: the point is independence, not availability.

Keep it on local block storage. Archive the previous day's log to S3 after the
EOD roll if you need retention. For live redundancy, run a **chained
tickerplant** in a second AZ; that gives you a replicated log, which is the
thing shared storage was being asked for.

### Backups

ZFS snapshots live on the filesystem, so they are a fast rollback, not a
backup — losing the filesystem loses them too. Push a real copy off it: AWS
Backup on a schedule, or export the day's partitions to S3 after the sort
completes. S3 is the thing that lets you rebuild from nothing.

## Operational rules the layout depends on

1. **One writer.** Only the sort process mounts `GAZ_HDB` read-write. Production
   readers mount `:ro`. `docker-compose.yml` encodes this. Developer clones are
   exempt — a clone is a separate volume with its own single writer.
2. **One UID.** NFS enforces POSIX ownership. Every instance and container must
   run q as the same numeric UID/GID or readers hit permission errors on files
   the sort process created. The Dockerfile pins `GAZ_UID=6000`.
3. **Readers must reload after write-down.** HDB processes hold mmaps and will
   not see a new partition until they reload. TorQ's sort process signals the
   hdb/rdb/gateway at EOD — verify that path works before trusting it, rather
   than papering over it with a cron reload.
4. **Mount with `flock`.** Not optional on NFS. Test the EOD reload path against
   a real NFS mount early — mmap-over-NFS coherency is the part of this design
   most likely to surprise you, and 3am is a bad time to find out.

## Compute notes

- **RDB**: memory-optimised (`r7i`, `x2idn`). Size RAM at 2–3× expected intraday
  volume — q needs query workspace on top of the data, and an OOM in the RDB
  loses today's in-memory state.
- **One instance to start.** TP, RDB, WDB, sort, HDB and gateway all on the same
  box — at the expected volume nothing here justifies a split, and a single host
  makes the EOD handoff trivial to reason about. Split when one process is
  measurably starving another, not before.
- **When you do split, move the HDB readers out first.** The TP -> RDB hop is the
  only latency-sensitive one in the stack; keep those two together for as long
  as they fit. HDB processes are read-only against the shared mount, so they are
  the cheapest thing to relocate.
- Disable transparent hugepages; set `vm.swappiness=0`. Cloud base images
  usually ship THP enabled, which hurts q.
- **Don't compress twice.** kdb+ compresses on write-down and ZFS compresses by
  default (LZ4). Pick one — doing both burns CPU for almost no extra ratio.
- Benchmark the OpenZFS **throughput capacity** (provisioned MB/s, not elastic)
  and the volume **record size** against your real query mix. The 128 KiB
  default is not obviously right for column reads.

## Alternatives considered

- **FSx for Lustre** — higher peak throughput, and a Data Repository Association
  makes S3 the system of record with lazy per-file hydration. Costs a 1.2 TiB
  minimum, is single-AZ only, and has no clone story. Revisit if the working set
  outgrows what fits comfortably on one filesystem.
- **FSx for NetApp ONTAP** — also NFS, also clones (FlexClone), multi-AZ HA,
  automatic tiering. A reasonable substitute; OpenZFS is the simpler of the two.
- **No shared filesystem.** Keep the HDB on plain EBS and give every reader its
  own volume from a snapshot. No mmap-over-network subtleties at all; costs a
  per-reader copy and a clunkier EOD.

## Licensing

kdb+ is licensed per core and the classic `k4.lic` is pinned to a host
identity, which does not survive instance recycling. Resolve this before
sizing anything:

- **kdb+ on-demand** via the AWS Marketplace — hourly, validates over the
  network. Best fit for elastic workloads.
- **Floating license** served by KX's license daemon (`QLIC` points at it) if
  you already hold a seat count.

Pin core counts with cgroups/`taskset` so moving to a larger instance does not
silently exceed your entitlement.
