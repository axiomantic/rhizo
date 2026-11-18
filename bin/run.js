#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync, execSync } = require('child_process');

const PKG_NAME = 'rhizo';
const REPO = `axiomantic/${PKG_NAME}`;
const VERSION = require('../package.json').version;

function isCompatibleBinary(filePath) {
  try {
    if (!fs.existsSync(filePath)) return false;
    const stat = fs.statSync(filePath);
    if (!stat.isFile() || stat.size < 64) return false;

    const fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(64);
    fs.readSync(fd, buf, 0, 64, 0);
    fs.closeSync(fd);

    const platform = process.platform;
    const arch = process.arch;

    if (platform === 'darwin') {
      const isMachO64 = (buf[0] === 0xcf && buf[1] === 0xfa && buf[2] === 0xed && buf[3] === 0xfe);
      const isFatMachO = (buf[0] === 0xca && buf[1] === 0xfe && buf[2] === 0xba && buf[3] === 0xbe);
      if (isFatMachO) return true;
      if (!isMachO64) return false;
      const cpuType = buf.readInt32LE(4);
      if (arch === 'arm64' && cpuType === 0x0100000c) return true;
      if (arch === 'x64' && cpuType === 0x01000007) return true;
      return false;
    }

    if (platform === 'linux') {
      const isELF = buf[0] === 0x7f && buf[1] === 0x45 && buf[2] === 0x4c && buf[3] === 0x46;
      if (!isELF) return false;
      const is64Bit = buf[4] === 2;
      if (!is64Bit) return false;
      const machine = buf.readUInt16LE(18);
      if (arch === 'x64' && machine === 62) return true; // EM_X86_64
      if (arch === 'arm64' && machine === 183) return true; // EM_AARCH64
      return false;
    }

    if (platform === 'win32') {
      return buf[0] === 0x4d && buf[1] === 0x5a;
    }

    return false;
  } catch (_) {
    return false;
  }
}

function resolveBinary() {
  const ext = process.platform === 'win32' ? '.exe' : '';
  const arch = process.arch === 'arm64' ? 'arm64' : 'amd64';
  const platform = process.platform === 'darwin' ? 'darwin' : (process.platform === 'linux' ? 'linux' : 'windows');

  // 1. Check local/bundled locations (Fat-Package and local builds)
  const candidates = [
    path.join(__dirname, 'binaries', `${PKG_NAME}-${process.platform}-${process.arch}${ext}`),
    path.join(__dirname, 'binaries', `${PKG_NAME}-${process.platform}-${process.arch === 'x64' ? 'amd64' : process.arch}${ext}`),
    path.join(__dirname, `${PKG_NAME}-${process.platform}-${process.arch}${ext}`),
    path.join(__dirname, `${PKG_NAME}${ext}`),
    path.join(__dirname, '..', 'vendor', 'bin', `${PKG_NAME}${ext}`),
  ];

  for (const cand of candidates) {
    if (isCompatibleBinary(cand)) {
      try { fs.chmodSync(cand, 0o755); } catch (_) {}
      return cand;
    }
  }

  // 2. Check user cache directory (~/.cache/<pkg>/bin/<pkg>)
  const cacheBase = process.env.XDG_CACHE_HOME || (
    process.platform === 'win32'
      ? (process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'))
      : path.join(os.homedir(), '.cache')
  );
  const cacheBinDir = path.join(cacheBase, PKG_NAME, VERSION, 'bin');
  const cachedBin = path.join(cacheBinDir, `${PKG_NAME}${ext}`);

  if (isCompatibleBinary(cachedBin)) {
    return cachedBin;
  }

  // 3. Auto-download from GitHub releases
  const assetExt = process.platform === 'win32' ? '.zip' : '.tar.gz';
  const assetName = `${PKG_NAME}-${platform}-${arch}${assetExt}`;
  const downloadUrl = `https://github.com/${REPO}/releases/download/v${VERSION}/${assetName}`;

  try {
    fs.mkdirSync(cacheBinDir, { recursive: true });
    process.stderr.write(`[@axiomantic/${PKG_NAME}] Downloading native binary for ${platform}-${arch} from GitHub Releases...\n`);

    if (process.platform === 'win32') {
      const zipPath = path.join(cacheBinDir, assetName);
      execSync(`powershell -Command "Invoke-WebRequest -Uri '${downloadUrl}' -OutFile '${zipPath}'; Expand-Archive -Path '${zipPath}' -DestinationPath '${cacheBinDir}' -Force; Remove-Item '${zipPath}'"`, { stdio: 'inherit' });
    } else {
      execSync(`curl -fsSL "${downloadUrl}" | tar -xzf - -C "${cacheBinDir}"`, { stdio: 'inherit' });
    }

    if (isCompatibleBinary(cachedBin)) {
      try { fs.chmodSync(cachedBin, 0o755); } catch (_) {}
      return cachedBin;
    }
  } catch (err) {
    process.stderr.write(`[@axiomantic/${PKG_NAME}] Automatic download failed: ${err.message}\n`);
  }

  // 4. Fallback: compile from local source if nim is available
  const srcFile = path.join(__dirname, '..', 'src', `${PKG_NAME}.nim`);
  if (fs.existsSync(srcFile)) {
    try {
      const whichCmd = process.platform === 'win32' ? 'where nim' : 'which nim';
      execSync(whichCmd, { stdio: 'ignore' });
      process.stderr.write(`[@axiomantic/${PKG_NAME}] Building from source via Nim compiler...\n`);
      fs.mkdirSync(cacheBinDir, { recursive: true });
      execSync(`nim c -d:release --opt:speed -o:"${cachedBin}" "${srcFile}"`, { stdio: 'inherit' });
      if (isCompatibleBinary(cachedBin)) {
        try { fs.chmodSync(cachedBin, 0o755); } catch (_) {}
        return cachedBin;
      }
    } catch (_) {}
  }

  return null;
}

const binPath = resolveBinary();
if (!binPath) {
  console.error(`\nError: @axiomantic/${PKG_NAME} native binary not found or incompatible with ${process.platform}-${process.arch}.`);
  console.error(`Please visit https://github.com/${REPO}/releases to download, or install Nim (https://nim-lang.org) to compile from source.`);
  process.exit(1);
}

try {
  fs.chmodSync(binPath, 0o755);
} catch (_) {}

const res = spawnSync(binPath, process.argv.slice(2), {
  stdio: 'inherit',
  env: process.env
});

if (res.error) {
  console.error(`Failed to execute binary: ${res.error.message}`);
  process.exit(1);
}

process.exit(res.status !== null ? res.status : (res.signal ? 1 : 0));
