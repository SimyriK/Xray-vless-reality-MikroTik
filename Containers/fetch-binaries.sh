#!/bin/sh
# Скачивает Xray и hev-socks5-tunnel на этапе сборке.
# Fallback: xray-core/Xray-linux-${TARGETARCH}.7z
#           hev/hev-socks5-tunnel-linux-${TARGETARCH}.7z
set -eu

targetArch="${TARGETARCH:?TARGETARCH required}"   # amd64 | arm64 | arm (Docker)
outDir="/out"                                     # COPY --from=builder в Dockerfile
buildDir="${BUILD_DIR:-/build}"

# hev не имеет /releases/latest/download — только API или фиксированный тег
resolve_hev_version() {
  if [ -n "${HEV_VERSION:-}" ] && [ "${HEV_VERSION}" != "latest" ]; then
    printf '%s\n' "${HEV_VERSION}"
    return 0
  fi
  apiUrl="https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest"
  tag=$(wget -qO- "${apiUrl}" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
  if [ -z "${tag}" ]; then
    echo "failed to resolve latest hev-socks5-tunnel release" >&2
    return 1
  fi
  printf '%s\n' "${tag}"
}

hevVersion=$(resolve_hev_version)
echo "hev-socks5-tunnel version: ${hevVersion}"

xrayFallback="${buildDir}/xray-core/Xray-linux-${targetArch}.7z"
hevFallback="${buildDir}/hev/hev-socks5-tunnel-linux-${targetArch}.7z"

mkdir -p "${outDir}"

# GitHub asset names ≠ Docker TARGETARCH (arm → arm32v7, amd64 → x86_64)
remote_xray_zip() {
  case "${targetArch}" in
    amd64) echo "Xray-linux-64.zip" ;;
    arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    arm) echo "Xray-linux-arm32-v7a.zip" ;;
    *) echo "unsupported TARGETARCH: ${targetArch}" >&2; return 1 ;;
  esac
}

remote_hev_asset() {
  case "${targetArch}" in
    amd64) echo "hev-socks5-tunnel-linux-x86_64" ;;
    arm64) echo "hev-socks5-tunnel-linux-arm64" ;;
    arm) echo "hev-socks5-tunnel-linux-arm32v7" ;;
    *) echo "unsupported TARGETARCH: ${targetArch}" >&2; return 1 ;;
  esac
}

# Распаковка fallback .7z (p7zip есть только в builder)
extract_7z_binary() {
  archive="$1"
  unpackDir="$2"
  binName="$3"
  dest="$4"

  rm -rf "${unpackDir}"
  mkdir -p "${unpackDir}"
  7z x "${archive}" -o"${unpackDir}" -y
  binPath=$(find "${unpackDir}" -type f -name "${binName}" | head -n1)
  if [ -z "${binPath}" ]; then
    binPath=$(find "${unpackDir}" -type f ! -name "*.txt" | head -n1)
  fi
  if [ -z "${binPath}" ]; then
    echo "binary not found in ${archive}" >&2
    return 1
  fi
  cp "${binPath}" "${dest}"
  chmod 755 "${dest}"
  is_valid_elf "${dest}"
}

# Непустой ELF (отсекает HTML-ошибки GitHub и битые архивы)
is_valid_elf() {
  path="$1"
  [ -s "${path}" ] || return 1
  sig=$(head -c 4 "${path}" | od -An -tx1 | tr -d ' \n')
  [ "${sig}" = "7f454c46" ]
}

# Xray: /releases/latest/download/{zip}
fetch_xray_remote() {
  xrayZip=$(remote_xray_zip)
  xrayUrl="https://github.com/XTLS/Xray-core/releases/latest/download/${xrayZip}"
  echo "Fetching Xray: ${xrayUrl}"
  wget -qO /tmp/xray.zip "${xrayUrl}" || {
    echo "Xray: download failed" >&2
    return 1
  }
  rm -rf /tmp/xray-unpack
  mkdir -p /tmp/xray-unpack
  unzip -q -o /tmp/xray.zip -d /tmp/xray-unpack || {
    echo "Xray: unzip failed" >&2
    return 1
  }
  xrayBin=$(find /tmp/xray-unpack -type f -name xray | head -n1)
  if [ -z "${xrayBin}" ]; then
    echo "Xray: binary not found in ${xrayZip}" >&2
    return 1
  fi
  cp "${xrayBin}" "${outDir}/xray"
  chmod 755 "${outDir}/xray"
  is_valid_elf "${outDir}/xray" || {
    echo "Xray: invalid ELF after unzip" >&2
    rm -f "${outDir}/xray"
    return 1
  }
  echo "Xray: $("${outDir}/xray" version 2>/dev/null | head -n1 || echo unknown)"
}

fetch_xray_fallback() {
  archive="$1"
  if [ ! -f "${archive}" ]; then
    echo "Xray fallback archive missing: ${archive}" >&2
    return 1
  fi
  extract_7z_binary "${archive}" /tmp/xray-unpack xray "${outDir}/xray" || {
    echo "Xray: fallback extract failed" >&2
    return 1
  }
  echo "Xray (fallback): $("${outDir}/xray" version 2>/dev/null | head -n1 || echo unknown)"
}

fetch_xray() {
  fetch_xray_remote || fetch_xray_fallback "${xrayFallback}"
}

# hev: /releases/download/{tag}/{asset}
fetch_hev_remote() {
  hevName=$(remote_hev_asset)
  hevUrl="https://github.com/heiher/hev-socks5-tunnel/releases/download/${hevVersion}/${hevName}"
  echo "Fetching hev-socks5-tunnel ${hevVersion}: ${hevUrl}"
  wget -qO "${outDir}/hev-socks5-tunnel" "${hevUrl}" || {
    echo "hev: download failed" >&2
    return 1
  }
  chmod 755 "${outDir}/hev-socks5-tunnel"
  is_valid_elf "${outDir}/hev-socks5-tunnel" || {
    echo "hev: invalid ELF" >&2
    rm -f "${outDir}/hev-socks5-tunnel"
    return 1
  }
  echo "hev-socks5-tunnel: ${hevVersion} (${hevName})"
}

fetch_hev_fallback() {
  archive="$1"
  if [ ! -f "${archive}" ]; then
    echo "hev fallback archive missing: ${archive}" >&2
    return 1
  fi
  extract_7z_binary "${archive}" /tmp/hev-unpack hev-socks5-tunnel "${outDir}/hev-socks5-tunnel" || {
    echo "hev: fallback extract failed" >&2
    return 1
  }
  echo "hev-socks5-tunnel (fallback): ${archive}"
}

fetch_hev() {
  fetch_hev_remote || fetch_hev_fallback "${hevFallback}"
}

fetch_xray
fetch_hev
echo "Binaries ready in ${outDir}"
