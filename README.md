<h1 align="center">finns ❄️ dots</h1>

<p align="center">
  <a href="https://builtwithnix.org"><img src="https://img.shields.io/static/v1?logo=nixos&logoColor=white&label=&message=Built%20with%20Nix&color=41439a" alt="built with nix"></a>
  <a href="https://github.com/Multipixelone/infra/actions/workflows/ci.yml"><img src="https://github.com/Multipixelone/infra/actions/workflows/check.yaml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/github/languages/top/Multipixelone/infra?color=c6a0f6" alt="GitHub Language">
  <img src="https://img.shields.io/github/languages/code-size/Multipixelone/infra?color=fab387" alt="GitHub Code Size">
  <a href="https://github.com/Multipixelone/infra/blob/master/LICENSE"><img src="https://img.shields.io/github/license/Multipixelone/infra?color=a6e3a1" alt="License"></a>
</p>

## About

We won!! It's finally [dendritic](https://github.com/mightyiam/dendritic)!! Everything is beautiful and is all modules built on top of flake-parts. Each file is a top level flake-parts module that is imported by import-tree. This repository currently builds my laptop `zelda`, my desktop `link`, a Mac Mini as an Airport Express `marin` and an old Dell Laptop as my IoT server `iot`

## Things I Think Are Cool

- secrets are managed in a private repo and decrypted at runtime by `agenix`
- restic backups to **OneDrive**
- packages are built in a Github Action and pushed to an attic server running on **fly.io**
- music syncing between computers and a script to download my playlists on a timer
