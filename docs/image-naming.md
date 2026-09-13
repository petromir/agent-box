# Image naming: variant in the repository name or in the tag?

## Purpose

This document compares two ways to publish the `ai-agent-box` variants to a
container registry. It does not cover the short local build tags
(`ai-agent-box-opencode:local`, `ai-agent-box-omp:local`, and the two
`*-java:local` tags).

## Terms

An image reference has this shape:

    [registry/]namespace/repository[:tag]

- **Repository name** (also called image name) — the part before the colon,
  for example `ai-agent-box-omp`.
- **Tag** — the part after the colon, for example `<omp-version>`.
- **`latest`** — the default tag. A registry uses it when you pull an image
  without a tag.

A registry stores metadata **per repository**. Examples: description,
permissions, webhooks, vulnerability scanning, tag protection, retention
policy, and pull counters. This point matters for the comparison below.

## The two options

The examples below use placeholders for the version pins:

- `<opencode-version>` — the value of `OPENCODE_VERSION` in
  `opencode/opencode.Dockerfile`.
- `<omp-version>` — the value of `OMP_VERSION` in `omp/omp.Dockerfile`. It
  already includes the `v` prefix.
- `<jdk-major>` — the major version of `LIBERICA_VERSION` in
  `java/java-25.Dockerfile`.

Read the current values from the Dockerfiles. Do not copy them from this
document.

### Option 1 — variant in the repository name
```
ai-agent-box-opencode:<opencode-version>
ai-agent-box-omp:<omp-version>
ai-agent-box-opencode-java:<jdk-major>
ai-agent-box-omp-java:<jdk-major>
```
### Option 2 — variant in the tag
```
ai-agent-box:opencode.<opencode-version>
ai-agent-box:omp.<omp-version>
ai-agent-box:opencode.java.<jdk-major>
ai-agent-box:omp.java.<jdk-major>
```
## Option 1 — pros and cons

### Pros

- **Clean version tags.** The tag stays a plain version
  (for example `<omp-version>`). Every tool that reads a version — Renovate,
  Dependabot, Compose, Kubernetes — reads it without a special grammar.
- **One unambiguous `latest` per variant.** `ai-agent-box-omp:latest` and
  `ai-agent-box-opencode:latest` are different images. No conflict.
- **Independent `latest` updates.** You can promote one variant without
  touching the others.
- **Per-variant registry settings.** You can set a different description,
  permission, scanner, and retention policy for each variant.
- **No cross-variant collisions.** A bad `docker push` cannot overwrite
  another variant's tag.
- **Simple lifecycle.** You can delete, transfer, or make private one variant
  on its own.
- **Matches common convention.** Different products get different repositories
  (`python`, `node`, `postgres`). Flavors and versions stay in the tag.
- **Natural CI mapping.** Each `docker/build-push-action` step targets one
  repository. Each variant keeps its own buildx cache scope.
- **Clear access control.** You can give a team write access to only the
  variant they own.

### Cons

- **More repositories to manage.** Each one needs a name, a description, and
  possibly its own secrets or automation.
- **Discoverability is split.** A user must know the variant names. There is
  no single page that lists all variants.
- **Renaming the base breaks callers.** Renaming the opencode image from
  `ai-agent-box` to `ai-agent-box-opencode` breaks existing `docker pull`
  commands and pinned references.
- **The derived image needs the right base name.** The CI step for
  `ai-agent-box-omp-java` must reference the exact base repository and tag.

## Option 2 — pros and cons

### Pros

- **One repository.** One name to remember, one page to browse, one place for
  the description.
- **One set of registry settings.** One permission list, one webhook, one
  scanner configuration.
- **One buildx cache scope.** Buildx can share layers between variants more
  easily.
- **Simple pull URL shape.** `docker pull namespace/ai-agent-box:TAG` never
  changes the repository part.
- **Cheap to add a variant.** A new agent is a new tag, not a new repository.

### Cons

- **The tag grammar is ambiguous.** A dot `.` is a legal tag character and
  also a version separator. `ai-agent-box:omp.java.<jdk-major>` cannot be split
  safely: a script cannot tell whether the last field is a Java version or a
  patch level.
- **Only one `latest`.** One repository has one `latest`. It can describe only
  one variant. You must invent `opencode.latest`, `omp.latest`, and
  `omp.java.latest`, and move each one by hand.
- **The tag list mixes all variants.** Users and UIs cannot filter opencode
  tags from omp tags. The list gets noisy as versions accumulate.
- **Cross-variant collision risk.** A wrong tag string in CI can overwrite
  another variant's tag.
- **Immutable tags apply to the whole repository.** If you switch on immutable
  tags or signing policy for one variant, you switch it on for all of them.
- **Retention cannot differ per variant.** The policy is per repository, so a
  noisy variant keeps its old tags as long as the quiet variant.
- **Access control is all-or-nothing.** You cannot give a team write access to
  only the omp tags.
- **Tooling friction.** Some tools assume the tag is a version. A variant
  prefix in the tag can break version comparison and update bots.

## Side-by-side comparison

| Concern | Option 1 (name) | Option 2 (tag) |
|---------|-----------------|----------------|
| Version tag stays clean | Yes | No |
| Separate `latest` per variant | Yes | No |
| Tag grammar needed | No | Yes |
| Cross-variant collision | No | Yes |
| Per-variant registry settings | Yes | No |
| Per-variant access control | Yes | No |
| Per-variant retention | Yes | No |
| Repositories to manage | Many | One |
| Single page to browse all variants | No | Yes |
| Memory load for the user | Variant name | Variant + tag grammar |
| Matches common convention | Yes | No |

## Recommendation

Use **Option 1**: put the variant in the repository name and keep the tag as a
clean version.

Reasons, in order of weight:

1. Independent variants need independent `latest` tags. Option 2 cannot give
   them.
2. A dot separator is ambiguous. This is a real bug source in scripts.
3. Per-variant registry settings and access control are usually required.

### Concrete scheme

| Variant | Repository | Tag |
|---------|-----------|-----|
| OpenCode | `ai-agent-box-opencode` | `<opencode-version>` |
| omp | `ai-agent-box-omp` | `<omp-version>` |
| Java on the opencode base | `ai-agent-box-opencode-java` | `<jdk-major>` |
| Java on omp | `ai-agent-box-omp-java` | `<jdk-major>` |

This is the scheme the repository uses. The old short name `ai-agent-box` is
gone: it is renamed to `ai-agent-box-opencode`. That breaks existing pull
commands and pinned references. The project accepted that one-time cost in
exchange for separate `latest` tags and per-variant registry settings.

## Naming rules

Apply these rules with either option.

- **Let the repository name show the real base.** `ai-agent-box-omp-java` says
  the Java layer sits on omp. If the Java image derives from the opencode base,
  name it `ai-agent-box-opencode-java`.
- **Keep the tag exactly as the Dockerfile `ARG` holds.** opencode stores a
  plain `x.y.z` in `OPENCODE_VERSION` (no `v` prefix). omp stores a `vX.Y.Z`
  value in `OMP_VERSION` (with the `v` prefix). Do not add or drop a `v` in the
  CI step. Normalize the `ARG` values first if you want one style.
- **Never move a shared `latest` across variants.** In Option 2, this rule
  means you must not use a bare `latest` for a variant.
- **Respect the registry limits.** A tag may contain letters, digits, `.`,
  `_`, and `-`. The maximum length is 128 characters. A tag must not start with
  `.` or `-`.
- **Keep names lowercase for Docker Hub.** Repository names use lowercase
  letters, digits, `.`, `_`, and `-`.

## CI notes

The current workflow in `.github/workflows/docker.yml` already implements the
shape of Option 1:

- It reads each pinned version with `sed` from the Dockerfile `ARG` lines.
- It builds each variant in its own `docker/build-push-action` step.
- It pushes each variant to its own repository, with its own `latest`.
- It gives each variant its own buildx cache scope (`opencode`, `omp`,
  `opencode-java`, `omp-java`).

Option 1 needs almost no change to this workflow. Option 2 would need a new
tag-building step, one push step with many tags, and a decision about which
variant owns `latest`.

## User notes

- **Option 1** — the user picks the agent first, then the version:
  `docker run namespace/ai-agent-box-omp:<omp-version>`. The reference reads
  like a product and a release.
- **Option 2** — the user must remember one repository and a tag grammar:
  `docker run namespace/ai-agent-box:omp.java.<jdk-major>`. This is short only
  if the user already knows the grammar.

## Decision checklist

Choose **Option 1** if any answer below is "yes":

- Do the variants release on their own schedule?
- Do the variants have version numbers that cannot be compared?
- Do the variants need different permissions, scanners, or retention?
- Do you want a separate `latest` for each variant?

Choose **Option 2** only if all answers below are "yes":

- You must publish everything under one repository.
- You can define and enforce a tag grammar.
- You accept one `latest` for the whole repository.
- You do not need per-variant registry settings.
