#!/usr/bin/env bash
# Helpers for mongo demo scripts. Source after common.env.

# shellcheck source=../../../demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../demo-lib.sh"

find_primary_container() {
  local node primary host
  for node in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      continue
    fi
    primary="$(docker exec "${node}" mongosh --quiet --eval 'try { print(rs.isMaster().primary) } catch(e) { print("") }' 2>/dev/null || true)"
    primary="$(echo "${primary}" | tr -d '\r' | tail -n 1)"
    if [[ -z "${primary}" || "${primary}" == "null" ]]; then
      continue
    fi
    host="${primary%%:*}"
    case "${host}" in
      "${MONGO1}"|"${MONGO2}"|"${MONGO3}")
        if docker ps --format '{{.Names}}' | grep -qx "${host}"; then
          echo "${host}"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

wait_for_primary() {
  local i
  for i in $(seq 1 90); do
    if find_primary_container 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "PRIMARY 待ちがタイムアウトしました" >&2
  return 1
}

# After a SIGKILL, wait until the new PRIMARY sees at least one SECONDARY.
# Scanning immediately can miss majority-acked docs that are on the other
# survivor but not yet visible as a stable PRIMARY snapshot.
wait_for_secondary_member() {
  local container="$1"
  local i n
  for i in $(seq 1 60); do
    n="$(demo_mongosh_exec "${container}" 'print((rs.status().members || []).filter(m => m.stateStr === "SECONDARY").length)' "test" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | tail -n 1 || true)"
    if [[ "${n}" =~ ^[1-9][0-9]*$ ]]; then
      return 0
    fi
    sleep 1
  done
  echo "${container} の横に SECONDARY が出る待ちがタイムアウトしました" >&2
  return 1
}

# mongosh --eval prints the last expression after print(), often "undefined".
# Keep the first 24-char hex substring from ObjectId("…") / hex / mixed output.
extract_oid_hex() {
  local raw="$1"
  printf '%s' "${raw}" | tr -d '\r' | grep -oE '[0-9a-fA-F]{24}' | head -n 1 || true
}

normalize_oid() {
  extract_oid_hex "$1"
}

extract_oid_hex_all() {
  tr -d '\r' | grep -E '^[0-9a-fA-F]{24}$' || true
}

# w: 1 → 1 ; w: 'majority' → "majority"
demo_write_concern_json() {
  local w="${1//\'/}"
  if [[ "${w}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${w}"
  else
    printf '"%s"' "${w}"
  fi
}

# Copy the burst script onto every running replica member (files are per-container).
demo_install_insert_burst_script() {
  local lib_dir node
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
  for node in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
    if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      docker cp "${lib_dir}/mongosh-insert-burst.js" "${node}:/tmp/mongosh-insert-burst.js" >/dev/null
      docker exec -u 0 "${node}" chmod a+r /tmp/mongosh-insert-burst.js
    fi
  done
}

run_insert_clients() {
  local write_concern="$1"
  local success_file="$2"
  local client_count="${3:-3}"
  local duration_sec="${4:-20}"
  local primary tag w_json
  primary="$(wait_for_primary)"
  tag="wc_${write_concern//\'/}"
  w_json="$(demo_write_concern_json "${write_concern}")"

  : > "${success_file}"
  mkdir -p "${RUN_DIR}/clients"
  demo_install_insert_burst_script

  demo_mongosh "${primary}" "
printjson(db.${MONGO_COLL}.insertOne(
  { tag: '${tag}', client: 1, n: 0, at: new Date() },
  { writeConcern: { w: ${write_concern}, wtimeout: 5000 } }
))
" "${MONGO_DB}"

  local i
  for i in $(seq 1 "${client_count}"); do
    (
      local end=$((SECONDS + duration_sec))
      local cur remain params stub
      while (( SECONDS < end )); do
        # Re-resolve primary when the current mongosh session dies (SIGKILL / failover).
        cur="$(find_primary_container 2>/dev/null || echo "${primary}")"
        remain=$(( (end - SECONDS) * 1000 ))
        if (( remain <= 0 )); then
          break
        fi
        params="$(mktemp)"
        stub="$(mktemp)"
        printf '{"db":"%s","coll":"%s","tag":"%s","client":%s,"w":%s,"durationMs":%s}\n' \
          "${MONGO_DB}" "${MONGO_COLL}" "${tag}" "${i}" "${w_json}" "${remain}" > "${params}"
        printf '%s\n' "globalThis.__demoBurstJson = '/tmp/demo-insert-burst-${i}.json'; load('/tmp/mongosh-insert-burst.js');" > "${stub}"
        docker cp "${params}" "${cur}:/tmp/demo-insert-burst-${i}.json" >/dev/null || true
        docker cp "${stub}" "${cur}:/tmp/demo-insert-run-${i}.js" >/dev/null || true
        rm -f "${params}" "${stub}"
        docker exec -u 0 "${cur}" chmod a+r "/tmp/demo-insert-burst-${i}.json" "/tmp/demo-insert-run-${i}.js" 2>/dev/null || true
        docker exec "${cur}" mongosh --quiet --file "/tmp/demo-insert-run-${i}.js" 2>/dev/null \
          | extract_oid_hex_all >> "${success_file}" || true
        sleep 0.2
      done
    ) > "${RUN_DIR}/clients/client-${i}.log" 2>&1 &
  done

  echo "クライアント ${client_count} 台を起動しました（docker exec あたり 1 つの mongosh ループ、約 ${duration_sec} 秒、insert ごとの出力は省略）"
}

# Hidden _id presence check (no lecture prompt). Uses static --file script + JSON params.
count_doc_by_id() {
  local container="$1"
  local oid="$2"
  local out
  out="$(demo_mongosh_count_by_oid "${container}" "${oid}" "${MONGO_DB}" "${MONGO_COLL}" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  echo "${out:-0}"
}

# Show one acked _id lookup on the new PRIMARY (lecture transcript; the full scan stays hidden).
# Display still looks like ObjectId('hex'); execution reads the id from JSON, not generated JS.
# Optional 3rd arg is readConcern level (Phase 4: local, Phase 5: majority).
show_one_id_check() {
  local container="$1"
  local oid="$2"
  local read_concern="${3:-}"
  local js
  oid="$(extract_oid_hex "${oid}")"
  if [[ ! "${oid}" =~ ^[0-9a-fA-F]{24}$ ]]; then
    echo "表示できる 24 文字 hex の _id がありません（insert クライアントの出力が ObjectId ではありませんでした）。" >&2
    return 0
  fi
  echo
  echo "# ${container}"
  if [[ -n "${read_concern}" ]]; then
    js="print(db.${MONGO_COLL}.countDocuments({ _id: ObjectId('${oid}') }, { readConcern: { level: '${read_concern}' } }))"
  else
    js="print(db.${MONGO_COLL}.countDocuments({ _id: ObjectId('${oid}') }))"
  fi
  demo_print_js "${MONGO_DB}" "${js}"
  demo_mongosh_count_by_oid "${container}" "${oid}" "${MONGO_DB}" "${MONGO_COLL}" "${read_concern}"
}

# Batch-check acked hex ids on container. Sets scan_acked, scan_found,
# scan_missing, scan_sample_missing, scan_sample_found (unique _id).
# ACKED = FOUND + MISSING. Writes lost hexes to missing_file.
# Optional 4th arg is readConcern level (Phase 4: local, Phase 5: majority).
run_acked_id_scan() {
  local container="$1"
  local success_file="$2"
  local missing_file="$3"
  local read_concern="${4:-}"
  local scan
  scan="$(demo_mongosh_scan_acked_ids "${container}" "${success_file}" "${MONGO_DB}" "${MONGO_COLL}" "${read_concern}")"
  scan_acked="$(printf '%s\n' "${scan}" | awk '/^ACKED / { print $2; exit }')"
  scan_found="$(printf '%s\n' "${scan}" | awk '/^FOUND / { print $2; exit }')"
  scan_missing="$(printf '%s\n' "${scan}" | awk '/^MISSING / { print $2; exit }')"
  scan_sample_missing="$(printf '%s\n' "${scan}" | awk '/^SAMPLE_MISSING / { print $2; exit }')"
  scan_sample_found="$(printf '%s\n' "${scan}" | awk '/^SAMPLE_FOUND / { print $2; exit }')"
  scan_acked="${scan_acked:-0}"
  scan_found="${scan_found:-0}"
  scan_missing="${scan_missing:-0}"
  : > "${missing_file}"
  printf '%s\n' "${scan}" | awk '/^LOST / { print $2 }' >> "${missing_file}"
}

running_mongo_nodes() {
  local node
  for node in "${MONGO1}" "${MONGO2}" "${MONGO3}"; do
    if docker ps --format '{{.Names}}' | grep -qx "${node}"; then
      printf '%s\n' "${node}"
    fi
  done
}

# A _id is missing only if no running replica has it (intersection of per-node LOST).
# Use this for w:majority: "was the write lost from the set?", not only the new PRIMARY.
# Optional 3rd arg is readConcern level (Phase 5: majority).
run_acked_id_scan_survivors() {
  local success_file="$1"
  local missing_file="$2"
  local read_concern="${3:-}"
  local tmp node first=1 sample_found_saved=""
  local lost_so_far
  tmp="$(mktemp -d)"
  lost_so_far="${tmp}/lost-intersect"
  : > "${lost_so_far}"
  scan_acked=0
  scan_found=0
  scan_missing=0
  scan_sample_missing=""
  scan_sample_found=""
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    run_acked_id_scan "${node}" "${success_file}" "${tmp}/lost-${node}" "${read_concern}"
    if [[ -n "${scan_sample_found}" && -z "${sample_found_saved}" ]]; then
      sample_found_saved="${scan_sample_found}"
    fi
    if [[ "${first}" -eq 1 ]]; then
      sort -u "${tmp}/lost-${node}" > "${lost_so_far}"
      first=0
    else
      comm -12 "${lost_so_far}" <(sort -u "${tmp}/lost-${node}") > "${tmp}/lost-next"
      mv "${tmp}/lost-next" "${lost_so_far}"
    fi
  done < <(running_mongo_nodes)
  if [[ "${first}" -eq 1 ]]; then
    echo "走査できる稼働中の Replica Set メンバがありません。" >&2
    rm -rf "${tmp}"
    return 1
  fi
  : > "${missing_file}"
  if [[ -s "${lost_so_far}" ]]; then
    cat "${lost_so_far}" > "${missing_file}"
  fi
  scan_missing="$(grep -cve '^$' "${missing_file}" || true)"
  scan_found=$((scan_acked - scan_missing))
  scan_sample_missing="$(head -n 1 "${missing_file}" || true)"
  scan_sample_found="${sample_found_saved}"
  rm -rf "${tmp}"
}

wait_clients() {
  wait || true
}
