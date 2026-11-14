# ZeroDrive Release Notes

Add new releases at the top using `## vX.Y.Z — YYYY-MM-DD — Title`.
Both macOS and Windows updaters and the live release manifest use this file as the single source of truth.

## v3.1.0 — 2026-11-13 — Automatic Updates, Verified Releases & In-App Changelog
- Automatic update checks on launch, sign-in, and every 4 hours in the background on macOS and Windows
- Cryptographically signed updates using ECDSA P-256 + SHA-256 verification and native OS code signing
- Resumable downloads with HTTP Range recovery and atomic rollback if an install or verification fails
- Automatic post-update "What's New" changelog window (including cumulative notes when skipping multiple versions)
- View full release history anytime from Dashboard, Settings, Menu Bar, or Windows CLI (`--changelog`)

## v3.0.5 — 2026-11-10 — Apple FileProvider Extension, Windows Cloud Filter & Multi-Drive Isolation
- Native macOS Apple FileProvider extension (`ZeroDriveFileProvider.appex`) for instant 3 ms APFS placeholders
- Native Windows Cloud Files API (`cfapi.dll`) sync engine (`zerodrive-sync.exe`) with Explorer sidebar pinning
- Multi-Drive partitioning and isolated sub-vaults across macOS, Windows, and AI agent MCP tools
- Founders ($29/mo Pro, $297/mo Agency) checkout flow with instant signed license activation

## v3.0.0 — 2026-11-05 — ZeroDrive Studio 3.0 & 24/7 Hosted MCP Server
- Complete ZeroDrive Studio UI with live telemetry, Storage Reclaim Advisor, and Duplicate Protection Shield
- 24/7 hosted AI Agent MCP server on `api.zerodrive.dev/mcp` with Google OAuth 2.0 authentication
- Zero-latency NFS mount engine with persistent disk handle caching and high-speed direct cloud streaming
