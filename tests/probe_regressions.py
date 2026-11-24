#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys
import time


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from sandbox_runner import XraySandbox


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "xray_2go.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")
README = ROOT / "README.md"
README_TEXT = README.read_text(encoding="utf-8")


def assert_true(cond, msg):
    if not cond:
        raise AssertionError(msg)


def run_bash(script: str, timeout: int = 20) -> str:
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            ["bash", "-lc", script],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=True,
        )
    return cp.stdout


def run_bash_result(script: str) -> subprocess.CompletedProcess[str]:
    with XraySandbox() as sandbox:
        return subprocess.run(
            ["bash", "-lc", script],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )


def test_runtime_script_update_installs_and_runs_main_branch():
    out = run_bash(r'''
        source ./xray_2go.sh
        mkdir -p "$(dirname "${SELF_DEST}")" "${WORK_DIR}"
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${SELF_DEST}"
        printf '%s\n' '{"custom_plugin":{"enabled":true}}' > "${STATE_FILE}"
        curl() {
            local target="" url=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -o) target="$2"; shift ;;
                    https://*) url="$1" ;;
                esac
                shift
            done
            [ "$url" = 'https://raw.githubusercontent.com/Luckylos/xray-2go/main/xray_2go.sh' ] || return 1
            cat > "$target" <<'NEW_SCRIPT'
#!/usr/bin/env bash
set -eu
[ "$0" = "$X2G_TEST_ROOT/usr/local/bin/xray2go" ]
[ -x "$0" ]
[ "$(readlink -f "$X2G_TEST_ROOT/usr/local/bin/s")" = "$0" ]
grep -qx 'exit 0' "$0.bak"
grep -Fxq '{"custom_plugin":{"enabled":true}}' "$X2G_TEST_ROOT/etc/xray2go/state.json"
printf '%s\n' 'new menu loaded'
NEW_SCRIPT
        }
        module_dispatch config update_shortcut || exit 1
        echo 'old menu resumed'
    ''')
    assert_true('new menu loaded' in out and 'old menu resumed' not in out, out)


def test_runtime_script_update_restores_previous_backup_on_failure_and_signal():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$(dirname "$SELF_DEST")"
        printf 'current\n' > "$SELF_DEST"
        printf 'previous\n' > "$SELF_DEST.bak"
        ln -s "$SELF_DEST" "$SHORTCUT"
        curl() {
            while [[ $1 != -o ]]; do shift; done
            printf '#!/usr/bin/env bash\nexit 0\n' > "$2"
        }
        mv() {
            if [[ ${@: -2:1} == */xray2go && ${@: -1} == "$SELF_DEST" ]]; then
                if [[ $scenario == replace ]]; then return 1; fi
                command mv "$@" || return 1
                if [[ $scenario == parent_term ]]; then
                    kill -TERM "$supervisor"
                    sleep .2
                else
                    kill -s "$scenario" "$BASHPID"
                fi
                return
            fi
            command mv "$@"
        }
        for scenario in replace INT TERM; do
            if ( _install_main_script ); then exit 1; fi
            [[ $(<"$SELF_DEST") == current && $(<"$SELF_DEST.bak") == previous ]] || exit 1
        done
        (
            trap '_trap_int' TERM
            supervisor=$BASHPID scenario=parent_term
            module_config_update_shortcut
        ) && exit 1
        [[ $(<"$SELF_DEST") == current && $(<"$SELF_DEST.bak") == previous ]]
    ''')


def test_argo_domain_probe_reports_http_and_obeys_total_budget():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.domain="origin.fixture.invalid"'
        curl() {
            [[ "$*" == *'--max-time 15'* ]] || return 1
            printf '%s' "$http_status"
        }
        http_status=404
        output=$(argo_check_health)
        [[ $output == *'HTTP 404'* && $output == *'客户端'* ]]
        http_status=502
        if output=$(argo_check_health 2>&1); then exit 1; fi
        [[ $output == *'HTTP 502'* ]]
        http_status=000
        if output=$(argo_check_health 2>&1); then exit 1; fi
        [[ $output == *'未收到 HTTP 响应'* ]]
    ''', timeout=20)


def test_xray_core_upgrade_verifies_release_and_restores_running_core():
    result = run_bash_result(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$WORK_DIR"
        fixture=$(mktemp -d "$WORK_DIR/fixture.XXXXXX")
        export fixture CONFIG_FILE
        printf 'existing config\n' > "$CONFIG_FILE"
        cp "$CONFIG_FILE" "$fixture/config"
        cat > "$fixture/current" <<'CORE'
#!/bin/bash
if [ "$1" = version ]; then
    printf 'Xray 26.3.27 (Xray, Penetrates Everything.)\n'
elif [ "$1" = -test ] && [ "$2" = -c ]; then
    if [ "$3" = "$CONFIG_FILE" ]; then
        [ ! -e "$fixture/reject-config" ] && cmp -s "$fixture/config" "$3"
    else
        exit 0
    fi
else
    exit 1
fi
CORE
        chmod 755 "$fixture/current"
        cp -p "$fixture/current" "$XRAY_BIN"
        sed 's/26\.3\.27/26.11.9/' "$fixture/current" > "$fixture/new"
        python3 - "$fixture" <<'PYZIP'
from pathlib import Path
import sys
from zipfile import ZipFile
work = Path(sys.argv[1])
with ZipFile(work / 'release.zip', 'w') as release:
    release.write(work / 'new', 'xray')
PYZIP
        tag=v26.11.9
        curl() {
            case "$*" in
                *'/releases/latest') printf '{"tag_name":"%s"}\n' "$tag" ;;
                *'.zip.dgst')
                    if [ "$scenario" = bad-digest ]; then
                        printf 'SHA2-256= %064d\n' 0
                    else
                        printf 'SHA2-256= %s\n' "$(sha256sum "$fixture/release.zip" | cut -d' ' -f1)"
                    fi ;;
                *'.zip')
                    printf 'download\n' >> "$fixture/events"
                    while [ "$1" != -o ]; do shift; done
                    cp "$fixture/release.zip" "$2" ;;
                *) return 1 ;;
            esac
        }
        prompt() {
            printf 'confirm\n' >> "$fixture/events"
            if [ "$scenario" = concurrent ]; then
                cp "$fixture/new" "$XRAY_BIN"
                chmod 755 "$XRAY_BIN"
            fi
            printf -v "$2" '%s' "$answer"
        }
        svc_exec() { [ "$1" = status ] && [ -e "$fixture/running" ]; }
        svc_exec_mut() {
            [ "$1" = restart ] || return 1
            "$XRAY_BIN" version | awk '{print $2}' >> "$fixture/events"
            touch "$fixture/running"
        }
        svc_verify_health() {
            if "$XRAY_BIN" version | grep -qF 26.11.9; then
                case "$scenario" in
                    rollback) return 1 ;;
                    interrupted) kill -TERM "$BASHPID" ;;
                esac
            fi
            [ -e "$fixture/running" ]
        }

        scenario=cancel answer=n
        module_dispatch xray upgrade
        cmp "$XRAY_BIN" "$fixture/current"
        ! grep -qx download "$fixture/events" || exit 1

        : > "$fixture/events"
        answer=y tag=v26.3.27
        module_dispatch xray upgrade
        test ! -s "$fixture/events"
        tag=v25.12.9
        module_dispatch xray upgrade
        test ! -s "$fixture/events"

        tag=v26.11.9 scenario=bad-digest
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/current"
        tag=v26.12.0 scenario=wrong-release
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/current"
        tag=v26.11.9
        : > "$fixture/events"
        scenario=concurrent
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/new"
        ! grep -qx download "$fixture/events" || exit 1
        cp -p "$fixture/current" "$XRAY_BIN"
        touch "$fixture/running" "$fixture/reject-config"
        scenario=invalid-config
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/current"
        ! grep -Eq '^26\.' "$fixture/events" || exit 1
        rm "$fixture/reject-config"

        : > "$fixture/events"
        scenario=rollback
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/current"
        test "$(tail -n 2 "$fixture/events")" = $'26.11.9\n26.3.27'

        : > "$fixture/events"
        scenario=interrupted
        if module_dispatch xray upgrade; then exit 1; fi
        cmp "$XRAY_BIN" "$fixture/current"
        test "$(tail -n 2 "$fixture/events")" = $'26.11.9\n26.3.27'

        : > "$fixture/events"
        scenario=upgrade
        module_dispatch xray upgrade
        cmp "$XRAY_BIN" "$fixture/new"
        test "$(tail -n 1 "$fixture/events")" = 26.11.9
        cp -p "$fixture/current" "$XRAY_BIN"
        rm "$fixture/running"
        : > "$fixture/events"
        module_dispatch xray upgrade
        cmp "$XRAY_BIN" "$fixture/new"
        test ! -e "$fixture/running"
        cmp "$CONFIG_FILE" "$fixture/config"
        ! grep -Eq '^26\.' "$fixture/events" || exit 1

        rm "$XRAY_BIN" "$CONFIG_FILE"
        download_xray
        cmp "$XRAY_BIN" "$fixture/new"
        : > "$fixture/events"
        download_xray
        test ! -s "$fixture/events"
        test -z "$(find "$WORK_DIR" -maxdepth 1 -name '.xray-*.*' -print)"
        printf 'CORE_UPGRADE_CHECKS_PASSED\n'
    ''')
    assert result.returncode == 0, result.stdout
    assert 'CORE_UPGRADE_CHECKS_PASSED' in result.stdout


def test_runtime_script_update_leaves_existing_files_on_failure():
    out = run_bash(r'''
        source ./xray_2go.sh
        mkdir -p "$(dirname "${SELF_DEST}")"
        printf '%s\n' 'old script' > "${SELF_DEST}"
        ln -s "${SELF_DEST}" "${SHORTCUT}"
        curl() {
            while [ "$1" != -o ]; do shift; done
            case "$scenario" in
                download) printf partial > "$2"; return 1 ;;
                syntax) printf '%s\n' '#!/usr/bin/env bash' 'if' > "$2" ;;
                *) printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$2" ;;
            esac
        }
        for scenario in download syntax; do
            if module_dispatch config update_shortcut; then exit 1; fi
            grep -qx 'old script' "${SELF_DEST}" || exit 1
            [ "$(readlink "${SHORTCUT}")" = "${SELF_DEST}" ] || exit 1
            [ ! -e "${SELF_DEST}.bak" ] || exit 1
        done
        rm "${SHORTCUT}"
        printf '%s\n' 'unrelated command' > "${SHORTCUT}"
        scenario=conflict
        if module_dispatch config update_shortcut; then exit 1; fi
        grep -qx 'old script' "${SELF_DEST}" || exit 1
        grep -qx 'unrelated command' "${SHORTCUT}" || exit 1

        rm "${SHORTCUT}" "${SELF_DEST}"
        scenario=replace
        mv() {
            [ "${@: -1}" != "${SELF_DEST}" ] || return 1
            command mv "$@"
        }
        if module_dispatch config update_shortcut; then exit 1; fi
        [ ! -e "${SELF_DEST}" ] && [ ! -L "${SHORTCUT}" ] || exit 1
        [ -z "$(find "$(dirname "${SELF_DEST}")" -name '.xray2go-update.*' -print)" ] || exit 1
        echo 'existing files retained'
    ''')
    assert_true('existing files retained' in out, out)


def test_plugin_ports_and_links_preserve_module_boundaries():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        _G_STATE='{"uuid":"00000000-0000-4000-8000-000000000001"}'
        _PLUGIN_REGISTRY=(audit_a audit_b)
        _plg_audit_a_ports() { printf '%s\n' 24101/tcp; }
        _plg_audit_b_ports() { printf '%s\n' 24102/tcp 24102/udp; }
        _plg_audit_a_link() { printf '%s\n' example://alpha 'example://bad whitespace' 'plugin status'; }
        _plg_audit_b_link() { printf '%s\n' example://beta; }
        _plg_audit_a_inbound() { :; }
        _plg_audit_b_inbound() { :; }
        [ "$(fw_desired_rules)" = $'24101/tcp\n24102/tcp\n24102/udp' ]
        [ "$(plugin_collect_links audit_a)" = example://alpha ]
        [ "$(plugin_collect_links)" = $'example://alpha\nexample://beta' ]
        _PLUGIN_REGISTRY+=(socks)
        _plg_socks_ports() { :; }
        _plg_socks_link() { printf '%s\n' 'socks://example.invalid:1080'; }
        _plg_socks_inbound() { :; }
        scoped=$(module_dispatch socks show)
        [[ "$scoped" == *'socks://example.invalid:1080'* && "$scoped" != *example://* ]]
        exported=$(module_show_nodes)
        [[ "$exported" == *'example://alpha'* && "$exported" == *'socks://example.invalid:1080'* ]]
        config_apply() { :; }
        st_persist() { :; }
        fw_reconcile() { :; }
        enabled=$(_module_enable_commit_inner socks)
        [[ "$enabled" == *'socks://example.invalid:1080'* && "$enabled" != *example://* ]]
        _plg_socks_link() { :; }
        _module_enable_commit_inner socks >/dev/null
        _PLUGIN_REGISTRY=(audit_b)
        [ "$(fw_desired_rules)" = $'24102/tcp\n24102/udp' ]
        _PLUGIN_REGISTRY=(audit_a)
        [ "$(fw_desired_rules)" = 24101/tcp ]
        echo 'plugin boundaries verified'
    ''')
    assert_true('plugin boundaries verified' in out, out)


def test_uninstall_only_removes_managed_shortcut():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$(dirname "${SHORTCUT}")"
        prompt() { printf -v "$2" 'y'; }
        svc_exec_mut() { :; }
        fw_force_cleanup() { :; }
        rm() {
            local _arg _safe=()
            for _arg in "$@"; do
                case "${_arg}" in /var/run/*) continue ;; esac
                _safe+=("${_arg}")
            done
            command rm "${_safe[@]}"
        }
        is_systemd() { return 1; }
        lifecycle_rollback_sysctl() { :; }
        lifecycle_rollback_hosts() { :; }
        printf '%s\n' 'existing command' > "${SHORTCUT}"
        module_xray_uninstall
        grep -qx 'existing command' "${SHORTCUT}"
        rm -- "${SHORTCUT}"
        ln -s unrelated "${SHORTCUT}"
        module_xray_uninstall
        [ "$(readlink "${SHORTCUT}")" = unrelated ]
        rm -- "${SHORTCUT}"
        ln -s xray2go "${SHORTCUT}"
        module_xray_uninstall
        [ ! -L "${SHORTCUT}" ]
        echo 'shortcut ownership verified'
    ''')
    assert_true('shortcut ownership verified' in out, out)


def test_state_schema_preserves_existing_http_password():
    out = run_bash(r'''
        source ./xray_2go.sh
        _G_STATE='{"http":{"pass":"audit-original"},"ss2022":{"user_key":""}}'
        _st_normalize_schema
        [ "$(st_get '.http.pass')" = audit-original ] || exit 1
        echo 'HTTP password preserved'
    ''')
    assert_true('HTTP password preserved' in out, out)


def test_transaction_reloads_restored_config_after_persist_failure():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "${WORK_DIR}"
        printf '%s\n' 'old config' > "${CONFIG_FILE}"
        printf '%s\n' 'old config' > "${WORK_DIR}/running"
        _fw_restore_managed_snapshot() { :; }
        svc_exec() { [ "$1" = status ] && [ "$2" = "${_SVC_XRAY}" ]; }
        svc_is_enabled() { return 1; }
        svc_apply_xray() { :; }
        svc_reload_daemon() { :; }
        svc_exec_mut() {
            [ "$1" = restart ] && [ "$2" = "${_SVC_XRAY}" ] || return 1
            cp "${CONFIG_FILE}" "${WORK_DIR}/running"
        }
        config_apply() {
            printf '%s\n' 'new config' > "${CONFIG_FILE}"
            svc_reload_xray
        }
        st_persist() { grep -qx 'new config' "${WORK_DIR}/running" && return 1; return 2; }
        if _commit; then exit 1; fi
        grep -qx 'old config' "${CONFIG_FILE}"
        grep -qx 'old config' "${WORK_DIR}/running"
        echo 'rollback reloaded previous config'
    ''')
    assert_true('rollback reloaded previous config' in out, out)


def test_damaged_state_and_backup_are_preserved_until_recovery():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "${WORK_DIR}"
        printf '%s\n' 'damaged' > "${STATE_FILE}"
        backup="${STATE_FILE}.previous.bak"
        printf '%s\n' '{"extension":{"enabled":true}}' > "$backup"
        if st_init; then exit 1; fi
        grep -qx 'damaged' "${STATE_FILE}"
        _st_offer_recovery() { with_lock _st_restore_backup "$backup"; }
        st_init
        [ "$(st_get '.extension.enabled')" = true ]
        jq -e '.extension.enabled' "${STATE_FILE}" >/dev/null
        jq -e '.extension.enabled' "$backup" >/dev/null
        grep -qx 'damaged' "${STATE_FILE}".corrupt.*
        echo 'backup restored with damaged copy retained'
    ''')
    assert_true('backup restored with damaged copy retained' in out, out)


def test_custom_plugin_passes_install_preflight_and_survives_plan_reset():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        _G_STATE='{"uuid":"00000000-0000-4000-8000-000000000001","extension":{"enabled":true},"ports":{"extension":45678}}'
        _PLUGIN_REGISTRY=(extension)
        _plg_extension_enabled() { [ "$(st_get '.extension.enabled')" = true ]; }
        install_plan_reset_defaults
        [ "$(port_of extension)" = 45678 ]
        install_plan_validate
        st_set '.extension.enabled = false'
        if install_plan_has_enabled_module; then exit 1; fi
        echo 'custom plugin checked by preflight'
    ''')
    assert_true('custom plugin checked by preflight' in out, out)


def test_runtime_harness_does_not_touch_host_root():
    from sandbox_runner import XraySandbox

    host_root = Path("/etc/xray2go")

    def metadata(path: Path):
        if not path.exists():
            return (False, None, None)
        stat = path.stat()
        return (True, stat.st_mode, stat.st_mtime_ns)

    host_before = metadata(host_root)
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "printf 'root=%s\\n' \"${_X2G_ROOT}\"; "
                "printf 'work=%s\\n' \"${WORK_DIR}\"; "
                "printf 'xray=%s\\n' \"${XRAY_BIN}\"; "
                "printf 'argo=%s\\n' \"${ARGO_BIN}\"; "
                "printf 'config=%s\\n' \"${CONFIG_FILE}\"; "
                "printf 'state=%s\\n' \"${STATE_FILE}\"; "
                "printf 'plugins=%s\\n' \"${PLUGIN_DIR}\"; "
                "printf 'shortcut=%s\\n' \"${SHORTCUT}\"; "
                "printf 'self=%s\\n' \"${SELF_DEST}\"; "
                "printf 'sysctl=%s\\n' \"${_SYSCTL_FILE}\";",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        assert_true(cp.returncode == 0, f"sandbox source must succeed (rc={cp.returncode}): {cp.stdout}")
        expected_root = sandbox.root
        expected = {
            "root": expected_root,
            "work": expected_root / "etc/xray2go",
            "xray": expected_root / "etc/xray2go/xray",
            "argo": expected_root / "etc/xray2go/argo",
            "config": expected_root / "etc/xray2go/config.json",
            "state": expected_root / "etc/xray2go/state.json",
            "plugins": expected_root / "etc/xray2go/plugins",
            "shortcut": expected_root / "usr/local/bin/s",
            "self": expected_root / "usr/local/bin/xray2go",
            "sysctl": expected_root / "etc/sysctl.d/99-xray2go.conf",
        }
        actual = dict(
            line.split("=", 1)
            for line in cp.stdout.splitlines()
            if "=" in line
        )
        for name, path in expected.items():
            assert_true(actual.get(name) == str(path), f"{name} escaped sandbox: {actual.get(name)!r} != {path}")
        sandbox_path = sandbox.root

    assert_true(not sandbox_path.exists(), f"sandbox must be removed after harness exit: {sandbox_path}")
    assert_true(metadata(host_root) == host_before, "host /etc/xray2go changed during sandbox path probe")


def test_state_backup_and_restore_are_confined_to_sandbox():
    from sandbox_runner import XraySandbox

    host_root = Path("/etc/xray2go")

    def metadata(path: Path):
        if not path.exists():
            return (False, None, None)
        stat = path.stat()
        return (True, stat.st_mode, stat.st_mtime_ns)

    host_before = metadata(host_root)
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init
st_persist
st_set '.uuid = "11111111-1111-4111-8111-111111111111"'
st_persist
atomic_write_secret "${CONFIG_FILE}" '{"version":1}'
atomic_write_secret_with_backup "${CONFIG_FILE}" '{"version":2}' 2
atomic_write_secret "${WORK_DIR}/tunnel.yml" 'tunnel: fixture'

is_systemd() { return 0; }
_svc_write_file() {
    case "$1" in
        "${_X2G_ROOT}"/*) atomic_write "$1" "$2" ;;
        *) printf 'escaped_service_path=%s\\n' "$1" >&2; return 97 ;;
    esac
}
svc_apply_xray
xray_rc=$?
svc_apply_tunnel
tunnel_rc=$?
printf 'xray_rc=%s\\n' "${xray_rc}"
printf 'tunnel_rc=%s\\n' "${tunnel_rc}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        assert_true(cp.returncode == 0, f"sandbox artifact probe process failed: {cp.stdout}")
        assert_true("xray_rc=0" in cp.stdout, f"xray service artifact escaped sandbox: {cp.stdout}")
        assert_true("tunnel_rc=0" in cp.stdout, f"tunnel service artifact escaped sandbox: {cp.stdout}")

        expected_files = [
            sandbox.root / "etc/xray2go/state.json",
            sandbox.root / "etc/xray2go/config.json",
            sandbox.root / "etc/xray2go/.argo_env",
            sandbox.root / "etc/xray2go/tunnel.yml",
            sandbox.root / "etc/systemd/system/xray2go.service",
            sandbox.root / "etc/systemd/system/tunnel2go.service",
        ]
        for path in expected_files:
            assert_true(path.is_file(), f"expected sandbox artifact missing: {path}")

        state_backups = sorted((sandbox.root / "etc/xray2go").glob("state.json.*.bak"))
        config_backups = sorted((sandbox.root / "etc/xray2go").glob("config.json.*.bak"))
        assert_true(state_backups, "state backup must be retained inside sandbox")
        assert_true(config_backups, "config backup must be retained inside sandbox")
        for path in [expected_files[0], expected_files[1], expected_files[2], *state_backups, *config_backups]:
            assert_true(path.stat().st_mode & 0o777 == 0o600, f"sensitive artifact mode is not 0600: {path}")

        leftovers = [
            path
            for path in sandbox.root.rglob("*")
            if path.name.startswith(".tmp_") or path.name.startswith("probe_")
        ]
        assert_true(not leftovers, f"temporary artifacts leaked after fresh process exit: {leftovers}")

    assert_true(metadata(host_root) == host_before, "host /etc/xray2go changed during sandbox artifact probe")


def test_runtime_probe_matrix_runs_in_fresh_process():
    from probe_matrix import discover_probe_matrix, run_probe_matrix

    probe_source = Path(__file__)
    matrix = discover_probe_matrix(probe_source)
    assert_true(set(matrix) == {"static", "safe", "sandbox"}, "probe matrix must expose static/safe/sandbox categories")
    names = [name for category in matrix.values() for name in category]
    assert_true(len(names) == len(set(names)), "probe matrix must not duplicate test names")
    assert_true(matrix["static"], "probe matrix must discover static probes")
    assert_true(matrix["safe"], "probe matrix must discover subprocess probes")
    assert_true(matrix["sandbox"], "probe matrix must discover explicit sandbox probes")

    report = run_probe_matrix(probe_source, categories=("static", "safe", "sandbox"))
    assert_true(report["failed"] == [], f"fresh-process probe matrix failures: {report}")
    assert_true(report["executed"] == names, "probe matrix must execute every discovered probe exactly once")
    assert_true(all(item["pid"] > 0 for item in report["results"]), "each probe must report a child process")


def test_function_boundaries_after_source():
    out = run_bash(
        "source ./xray_2go.sh; "
        "declare -F _pause _hr _print_link urlencode_path redact_sensitive prompt_secret; "
        "type _hr >/dev/null"
    )
    for fn in ["_pause", "_hr", "_print_link", "urlencode_path", "redact_sensitive", "prompt_secret"]:
        assert_true(fn in out, f"{fn} must be declared after sourcing script")


def test_cf_zone_uses_runtime_token_and_safe_query():
    m = re.search(r"acme_cf_find_zone\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(m, "acme_cf_find_zone function missing")
    body = m.group("body")
    assert_true("Authorization: Bearer" in body and "_token" in body, "Cloudflare Zone API must use runtime token variable")
    assert_true("Bearer ***" not in body, "redacted placeholder must not be used for real API auth")
    assert_true("--get" in body, "Cloudflare zone query should use curl --get")
    assert_true("--data-urlencode" in body and "_name" in body, "Cloudflare zone name must be URL encoded")
    assert_true("status=active" in body, "Cloudflare zone status must be encoded")


def test_acme_output_is_redacted_before_printing():
    assert_true("redact_sensitive()" in TEXT, "redaction helper missing")
    assert_true('printf \'%s\\n\' "${_issue_out}" | redact_sensitive' in TEXT, "ACME output must be redacted before printing")
    assert_true('_last_out="${_issue_out}"' in TEXT, "raw ACME output should remain available for retry/error detection")


def test_commit_fails_closed_on_state_persist():
    assert_true('st_persist || log_warn' not in TEXT, "state persistence must not be warn-only")
    assert_true('拒绝同步防火墙以避免状态漂移' in TEXT, "commit/disable paths should fail closed before firewall sync")


def test_install_port_conflict_uses_plugin_rules_and_udp():
    assert_true('for _proto in argo reality vltcp' not in TEXT, "install port check must not use hard-coded protocol list")
    assert_true('_rules=$(fw_desired_rules "${_preview}")' in TEXT and 'while IFS= read -r _rule; do' in TEXT, "install port check should derive from desired firewall rules")
    assert_true('port_mgr_in_use_udp' in TEXT, "install port check must cover UDP")


def test_firewall_does_not_mark_preexisting_rules_as_managed():
    assert_true('_fw_select_backend()' in TEXT, "firewall backend selector missing")
    assert_true('if _fw_rule_exists "${_backend}" "${_port}" "${_proto}"; then' in TEXT, "pre-existing firewall rules should be detected")
    assert_true('pre-existing rule is not script-owned; do not mark it as managed' in TEXT, "pre-existing rules should not be marked as script-managed")


def test_firewalld_preserves_preexisting_runtime_and_permanent_rules():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$WORK_DIR"
        firewall-cmd() {
            case "$*" in
                '--permanent --list-ports') printf '29002/tcp\n' ;;
                '--list-ports') printf '29001/tcp\n' ;;
                --query-port=*) return 1 ;;
                '--permanent --add-port=29003/tcp'|'--add-port=29003/tcp') printf '%s\n' "$*" >> "$WORK_DIR/changes" ;;
                *) return 1 ;;
            esac
        }
        _fw_open_port_backend firewalld 29001 tcp
        _fw_open_port_backend firewalld 29002 tcp
        [[ ! -e $_FW_RULES_FILE && ! -e $WORK_DIR/changes ]]
        _fw_open_port_backend firewalld 29003 tcp
        grep -qx 'firewalld:29003/tcp' "$_FW_RULES_FILE"
        grep -qx -- '--permanent --add-port=29003/tcp' "$WORK_DIR/changes"
        grep -qx -- '--add-port=29003/tcp' "$WORK_DIR/changes"
    ''')


def test_secret_prompt_exists():
    assert_true('prompt_secret()' in TEXT, "prompt_secret helper missing")
    for label in ["Cloudflare API Token", "Cloudflare Global API Key", "Argo 固定 Tunnel token", "私钥路径"]:
        assert_true(f'prompt "{label}' not in TEXT, f"sensitive prompt should not echo: {label}")


def test_home_fallback_is_initialized_for_process_substitution_runs():
    assert_true('if [ -z "${HOME:-}" ]; then' in TEXT and 'export HOME="${_DETECTED_HOME}"' in TEXT, 'script should initialize HOME fallback before later HOME-dependent logic')
    out = run_bash("""
        unset HOME
        source ./xray_2go.sh
        printf 'home=%s\\n' "${HOME}"
    """)
    assert_true('home=/' in out, 'script should initialize HOME when unset')


def test_backup_retention_two():
    assert_true('atomic_write_secret_with_backup "${STATE_FILE}" "${_json}" 2' in TEXT, "state backup retention should be 2")
    assert_true('atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 2' in TEXT, "config backup retention should be 2")


def test_systemd_hardening_templates():
    for token in ["PrivateTmp=yes", "ProtectHome=yes", "ProtectSystem=full", "ReadWritePaths=%s", "StandardOutput=journal", "StandardError=journal"]:
        assert_true(token in TEXT, f"systemd hardening token missing: {token}")


def test_vlquic_link_includes_explicit_h3_parameters():
    import json
    from urllib.parse import parse_qs, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.vlquic.enabled=true | .vlquic.domain="h3.example.com"'
        plugin_refresh_runtime
        plugin_collect_links vlquic
    ''')
    link = urlsplit(next(line for line in out.splitlines() if line.startswith('vless://')))
    query = parse_qs(link.query)
    assert link.fragment == 'VLESS-XHTTP-H3'
    assert query['type'] == ['xhttp'] and query['mode'] == ['stream-one'] and query['alpn'] == ['h3']
    assert query['xhttpModeH3'] == ['true'] and json.loads(query['extra'][0]) == {'xhttpModeH3': True}


def test_cforigin_edge_h3_toggle_and_link():
    assert_true('"edge_h3": false' in TEXT, "CF Origin edge_h3 default missing")
    assert_true(".cforigin.edge_h3 = false" in TEXT, "CF Origin edge_h3 normalization/reset missing")
    assert_true("实验性客户端到 Cloudflare Edge HTTP/3" in TEXT, "initial CF Origin Edge HTTP/3 prompt must mark experimental")
    assert_true("切换客户端到 Cloudflare Edge HTTP/3" in TEXT, "CF Origin management toggle missing")
    assert_true("CF-Origin-XHTTP-H3-Experimental" in TEXT, "CF Origin H3 link tag must mark experimental")
    assert_true("这不是 H3/QUIC 源站回源" in TEXT, "Cloudflare hint must clarify Edge H3 is not origin H3")
    assert_true("失败可回退普通 XHTTP/WS" in TEXT, "Cloudflare H3 prompt/hint must include rollback path")


def test_state_migrates_legacy_cforigin_port():
    assert_true('.cforigin.port // empty' in TEXT and "_st_migrate_port '.cforigin.port' '.ports.cforigin'" in TEXT and 'del(${_legacy_path})' in TEXT, "legacy cforigin.port must migrate into ports.cforigin")


def test_firewall_sync_fails_closed_and_prefers_active_managers():
    assert_true("ufw status" in TEXT and TEXT.index("ufw status") < TEXT.index("_fw_has_nftables; then printf 'nft'"), "active ufw should be preferred before raw nft")
    open_body = TEXT[TEXT.index('_fw_open_port()'):TEXT.index('_fw_close_port()')]
    assert_true('return 1' in open_body, "_fw_open_port must propagate backend failures")
    assert_true('_failed=0' in TEXT and '_fw_open_port "${_rp}" "${_rproto}" || _failed=1' in TEXT, "fw_reconcile must track firewall open failures")
    assert_true('部分防火墙规则同步失败' in TEXT, "fw_reconcile must report partial firewall failures")
    close_body = TEXT[TEXT.index('_fw_close_port()'):TEXT.index('fw_reconcile()')]
    assert_true('[[ "${_handle}" =~ ^[0-9]+$ ]] || return 1' in close_body, "nft cleanup must preserve ambiguous duplicate rules and their ledger entry")


def test_config_detects_wildcard_listen_conflicts_by_transport():
    result = run_bash_result(r'''
        source ./xray_2go.sh
        set -e
        st_init
        transport=udp listen=0.0.0.0
        _plg_one_ports() { printf '443\n'; }
        _plg_one_inbound() { printf '{"port":443,"listen":"192.0.2.10"}\n'; }
        _plg_two_ports() { printf '443/%s\n' "$transport"; }
        _plg_two_inbound() { printf '{"port":443,"listen":"%s"}\n' "$listen"; }
        _PLUGIN_REGISTRY=(one two)
        test "$(fw_desired_rules preview)" = $'443/tcp\n443/udp'
        _plugin_snapshot_rebuild
        test "$(fw_desired_rules)" = $'443/tcp\n443/udp'
        transport=tcp
        if _plugin_snapshot_rebuild; then exit 1; fi
        listen=192.0.2.11
        _plugin_snapshot_rebuild
        _PLUGIN_REGISTRY=(two one)
        listen=0.0.0.0
        if _plugin_snapshot_rebuild; then exit 1; fi
        echo LISTENER_CONFLICT_TESTS_PASSED
    ''')
    assert result.returncode == 0, result.stdout
    assert 'LISTENER_CONFLICT_TESTS_PASSED' in result.stdout


def test_firewall_reconcile_preserves_rules_on_plugin_port_failure():
    result = run_bash_result(r'''
        source ./xray_2go.sh
        set -e
        st_init
        _PLUGIN_REGISTRY=(failed)
        _plg_failed_ports() { printf '8443/tcp\n'; return 1; }
        _plg_failed_inbound() { :; }
        mkdir -p "$WORK_DIR"
        printf 'ufw:443/tcp\n' > "$_FW_RULES_FILE"
        _fw_close_port() { echo UNEXPECTED_RULE_CHANGE; }
        _fw_open_port() { echo UNEXPECTED_RULE_CHANGE; }
        if fw_desired_rules preview; then exit 1; fi
        if fw_reconcile; then exit 1; fi
        test "$(<"$_FW_RULES_FILE")" = 'ufw:443/tcp'
        echo FIREWALL_PORT_FAILURE_TEST_PASSED
    ''')
    assert result.returncode == 0, result.stdout
    assert 'FIREWALL_PORT_FAILURE_TEST_PASSED' in result.stdout
    assert 'UNEXPECTED_RULE_CHANGE' not in result.stdout


def test_runtime_field_save_reconciles_custom_plugin_ports_and_rolls_back():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.socks.enabled = true | .socks.listen = "127.0.0.1"'
        mkdir -p "$PLUGIN_DIR"
        cat > "$PLUGIN_DIR/custom.sh" <<'PLUGIN'
_plg_custom_enabled() { return 0; }
_plg_custom_link() { :; }
_plg_custom_port() {
    case "$(st_get '.socks.listen')" in
        127.0.0.1) printf 29001 ;;
        127.0.0.2) printf 29002 ;;
        127.0.0.3) printf 29003 ;;
    esac
}
_plg_custom_ports() { printf '%s/tcp\n' "$(_plg_custom_port)"; }
_plg_custom_inbound() { printf '{"tag":"custom","port":%s,"protocol":"socks"}\n' "$(_plg_custom_port)"; }
PLUGIN
        _PLUGIN_REGISTRY=(socks custom)
        _plugin_write_socks > "$PLUGIN_DIR/socks.sh"
        source "$PLUGIN_DIR/socks.sh"
        source "$PLUGIN_DIR/custom.sh"
        svc_exec() { return 1; }
        svc_is_enabled() { return 1; }
        svc_reload_daemon() { return 0; }
        platform_get_realip() { printf '203.0.113.10'; }
        _fw_select_backend() { printf ufw; }
        _fw_remove_rule() { return 0; }
        _fw_open_port_backend() {
            [[ $2 != 29003 ]] || return 1
            _fw_mark_rule "$@"
        }
        _commit
        prompt() { IFS= read -r "$2"; }
        module_socks_update_listen <<< '127.0.0.2'
        jq -e '.inbounds[] | select(.tag == "custom") | .port == 29002' "$CONFIG_FILE"
        grep -Fxq 'ufw:29002/tcp' "$_FW_RULES_FILE" || exit 41
        if grep -Fxq 'ufw:29001/tcp' "$_FW_RULES_FILE"; then exit 42; fi
        if module_socks_update_listen <<< '127.0.0.3'; then exit 43; fi
        jq -e '.socks.listen == "127.0.0.2"' "$STATE_FILE"
        jq -e '.inbounds[] | select(.tag == "custom") | .port == 29002' "$CONFIG_FILE"
        grep -Fxq 'ufw:29002/tcp' "$_FW_RULES_FILE"
    ''', timeout=50)


def test_builtin_plugin_refresh_and_cleanup_share_file_ownership():
    result = run_bash_result(r'''
        source ./xray_2go.sh
        set -e
        st_init
        mkdir -p "$PLUGIN_DIR"
        printf '%s\n' '# unmanaged file' 'touch "$WORK_DIR/unmanaged-sourced"' > "$PLUGIN_DIR/argo.sh"
        cp "$PLUGIN_DIR/argo.sh" "$WORK_DIR/original"
        printf '%s\n' '# xray-2go plugin: socks (previous template)' > "$PLUGIN_DIR/socks.sh"
        plugin_refresh_runtime
        cmp "$WORK_DIR/original" "$PLUGIN_DIR/argo.sh" || exit 52
        [[ ! -e $WORK_DIR/unmanaged-sourced ]]
        [[ " ${_PLUGIN_REGISTRY[*]} " == *' argo '* ]]
        declare -F _plg_argo_inbound >/dev/null
        grep -Fq '_plg_socks_inbound()' "$PLUGIN_DIR/socks.sh"
        _uninstall_managed_files
        cmp "$WORK_DIR/original" "$PLUGIN_DIR/argo.sh"
        [[ ! -e $PLUGIN_DIR/socks.sh ]]
    ''')
    assert result.returncode == 0, result.stdout


def test_plugin_loader_validates_before_source_and_loads_in_subshell():
    body = TEXT[TEXT.index('plugin_load_all()'):TEXT.index('plugin_install_builtins()')]
    assert_true('val_plugin_name "${_name}"' in body, "plugin loader must validate plugin filename before source")
    assert_true('_plugin_contract_ok' in body, "plugin loader must inspect plugin contract before source")
    assert_true('bash -n "${_f}"' in TEXT, "plugin loader must syntax-check plugin before source")
    assert_true('(\n        # 先在子 shell' in TEXT and 'source "${_f}" >/dev/null 2>&1 || exit 1' in TEXT, "plugin contract check should source in a subshell first")
    assert_true('插件文件名不合法' in TEXT and '接口不完整，已跳过且未加载' in TEXT, "plugin loader should report rejected plugins clearly")


def test_plugin_refresh_runtime_is_the_single_bootstrap_entry():
    refresh_body = TEXT[TEXT.index('plugin_refresh_runtime()'):TEXT.index('\n}\n', TEXT.index('plugin_refresh_runtime()'))]
    assert_true('plugin_install_builtins' in refresh_body and 'plugin_load_all' in refresh_body, 'plugin refresh must own builtin write + registry rebuild')
    install_core_body = TEXT[TEXT.index('module_xray_install_core()'):TEXT.index('\n}\n', TEXT.index('module_xray_install_core()'))]
    main_body = TEXT[TEXT.index('main()'):TEXT.index('if [ "${BASH_SOURCE[0]}" = "$0" ]; then', TEXT.index('main()'))]
    assert_true('plugin_refresh_runtime' in install_core_body, 'install core should reuse plugin_refresh_runtime')
    assert_true('plugin_refresh_runtime' in main_body, 'main entry should reuse plugin_refresh_runtime')


def test_plugin_collectors_drive_firewall_config_and_node_output():
    fw_body = TEXT[TEXT.index('fw_desired_rules()'):TEXT.index('\n}\n', TEXT.index('fw_desired_rules()'))]
    cfg_body = TEXT[TEXT.index('config_build_inbounds()'):TEXT.index('\n}\n', TEXT.index('config_build_inbounds()'))]
    nodes_body = TEXT[TEXT.index('config_print_nodes()'):TEXT.index('\n}\n', TEXT.index('config_print_nodes()'))]
    snapshot_body = TEXT[TEXT.index('_plugin_snapshot_rebuild()'):TEXT.index('\n}\n', TEXT.index('_plugin_snapshot_rebuild()'))]
    assert_true('plugin_collect_ports_raw' in fw_body, 'firewall desired rules should use shared plugin port collector')
    assert_true('plugin_collect_inbounds' in cfg_body, 'config_build_inbounds should delegate to shared inbound collector')
    assert_true('plugin_collect_links' in nodes_body, 'node output should delegate to shared link collector')
    for token in ['_PLUGIN_SNAPSHOT_PORTS', '_PLUGIN_SNAPSHOT_LINKS', '_PLUGIN_SNAPSHOT_INBOUNDS', '_plugin_port_rules "${_name}"', 'plugin_call "${_name}" link', 'plugin_call "${_name}" inbound']:
        assert_true(token in snapshot_body, f'plugin snapshot rebuild should collect all plugin dimensions once: {token}')


def test_argo_env_final_token_validation_and_menu_install_state():
    env_body = TEXT[TEXT.index('_svc_write_argo_env()'):TEXT.index('svc_apply_xray()')]
    assert_true('val_argo_token' in env_body, "Argo env writer must revalidate final token before writing env")
    assert_true('Argo token 格式异常，拒绝写入 env' in TEXT, "Argo env writer should fail closed on invalid persisted token")
    assert_true('check_xray_install()' in TEXT and '_MENU_XI' in TEXT, "menu should track installed state separately from running state")
    assert_true('Xray-2go 已安装但未运行' in TEXT, "install menu should not treat stopped service as uninstalled")
    assert_true('自动修正' not in TEXT and '不会自动更换' in TEXT, "port conflict prompts must match current fail/manual behavior")


def test_install_service_and_firewall_fail_closed_status():
    install_body = TEXT[TEXT.index('module_xray_install_core()'):TEXT.index('module_xray_uninstall()')]
    helper_body = TEXT[TEXT.index('svc_enable_start_verify()'):TEXT.index('# ==============================================================================', TEXT.index('svc_enable_start_verify()'))]
    assert_true('fw_reconcile || return 1' in install_body, "install must fail when firewall reconciliation fails")
    assert_true('svc_enable_start_verify "${_SVC_XRAY}" 8 required' in install_body, "xray install start path should use shared verified start helper")
    assert_true('svc_enable_start_verify "${_SVC_TUNNEL}" 6 required' in install_body, "Argo install must require verified Tunnel startup")
    assert_true('svc_exec_mut enable "${_svc}"' in helper_body and 'svc_exec_mut start  "${_svc}"' in helper_body, "service helper must centralize enable/start")
    assert_true('svc_verify_health "${_svc}" "${_max}"' in helper_body, "service helper must verify health when max wait > 0")
    assert_true('log_ok "${_svc} 已启动"' in helper_body, "service helper success message missing")
    assert_true('log_warn "${_svc} 启动失败' in helper_body, "optional service start failure warning missing")


def test_argo_install_tunnel_failure_rolls_back_before_state_commit():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true' >/dev/null
        clear() { :; }
        platform_preflight() { :; }
        plugin_refresh_runtime() { :; }
        _install_detect_existing_xray() { return 1; }
        _install_check_port_conflicts() { :; }
        download_xray() { :; }
        download_cloudflared() { :; }
        _argo_prepare_fixed_tunnel_from_state() { :; }
        config_apply() { printf fixture > "$CONFIG_FILE"; }
        svc_apply_xray() { :; }
        svc_apply_tunnel() { :; }
        svc_reload_daemon() { :; }
        is_openrc() { return 1; }
        platform_fix_time_sync() { :; }
        fw_reconcile() { :; }
        svc_enable_start_verify() {
            printf 'svc-call=%s max=%s mode=%s\\n' "$1" "$2" "$3"
            [ "$1" = "${_SVC_TUNNEL}" ] && return 1
            return 0
        }
        st_persist() { printf 'state-persist-called\\n'; return 0; }
        _transaction_run "fixture deployment" module_xray_install_core
        rc=$?
        [[ ! -e $CONFIG_FILE ]] || exit 1
        printf 'install-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true(cp.returncode == 0, f"Argo install failure probe process failed: {cp.stdout}")
    assert_true("svc-call=tunnel2go max=6 mode=required" in cp.stdout, f"Argo install must use required Tunnel health verification: {cp.stdout}")
    assert_true("install-rc=1" in cp.stdout and "state-persist-called" not in cp.stdout, f"Tunnel failure must fail before state persistence: {cp.stdout}")


def test_argo_restart_health_failure_restores_service_lifecycle():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        restart) _SERVICE_ACTIVE=0; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        disable) _SERVICE_ENABLED=0; return 0 ;;
    esac
    return 1
}
svc_verify_health() { printf 'argo-health-called\\n'; return 1; }
module_argo_restart >/dev/null 2>&1
_rc=$?
printf 'rc=%s active=%s enabled=%s\\n' "${_rc}" "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo restart rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 active=1 enabled=1" in cp.stdout,
        f"Argo restart health failure must restore service lifecycle state: {cp.stdout}",
    )


def test_menu_status_and_commit_helpers_are_shared():
    menu_helpers = TEXT[TEXT.index('_menu_input_port_proto()'):TEXT.index('check_xray_install()')]
    for helper in ['_xray_runtime_status()', '_menu_print_module_status()', '_module_apply_persist_print()', '_unified_mode_label()', '_unified_render_mode_header()', '_unified_runtime_status_for()', '_unified_runtime_toggle()']:
        assert_true(helper in TEXT or helper in menu_helpers, f"shared menu helper missing: {helper}")



def test_single_file_module_registry_drives_main_status():
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http ss2022"' in TEXT, "single-file module registry must list all modules")
    for name in ['_MODULE_LABELS', '_MODULE_MENU_FN', '_MODULE_RESTART_TARGET', '_MODULE_ENABLE_FN', '_MODULE_DISABLE_FN', '_MODULE_UNINSTALL_FN', '_MODULE_UPDATE_PORT_FN', '_MODULE_UPDATE_LISTEN_FN']:
        assert_true(name in TEXT, f"module metadata missing: {name}")
    assert_true('module_summary()' in TEXT and 'module_label()' in TEXT and 'module_registry_has()' in TEXT, "module metadata helpers missing")
    assert_true('module_dispatch()' in TEXT, "module dispatcher missing")


def test_single_file_module_dispatch_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['_action=', 'xray:install)', 'xray:uninstall)', 'nodes:show)', 'config:update_uuid)', 'config:update_shortcut)', 'module_registry_dispatch_common', 'module_registry_has']:
        assert_true(token in dispatch_body, f"module_dispatch action route missing: {token}")
    for fn in ['module_xray_install()', 'module_xray_uninstall()', 'module_nodes_show()', 'module_config_update_uuid()', 'module_config_update_shortcut()', 'module_xray_restart()', 'module_argo_restart()', 'module_show_nodes()', 'module_cforigin_show()']:
        assert_true(fn in TEXT, f"module action helper missing: {fn}")
    for marker in ['# core/global actions', '# Common module actions are dispatched from the registry above.', '# field/config update actions', '# key/toggle actions', '# complex/specialized actions']:
        assert_true(marker in dispatch_body, f"module_dispatch should be grouped for readability: {marker}")
    assert_true('module_dispatch reality restart' in TEXT and 'module_dispatch vltcp show' in TEXT, "module menus should route representative actions through shared dispatch")


def test_single_file_module_enable_disable_actions():
    assert_true('_MODULE_ENABLE_FN' in TEXT and '_MODULE_DISABLE_FN' in TEXT, "registry lifecycle maps are missing")
    for fn in ['module_ff_enable()', 'module_ff_disable()', 'module_reality_enable()', 'module_vltcp_enable()', 'module_cforigin_enable()', 'module_cforigin_disable()', 'module_socks_enable()', 'module_socks_disable()', 'module_http_enable()', 'module_http_disable()']:
        assert_true(fn in TEXT, f"module enable/disable helper missing: {fn}")
    for body_name, mod, plan_fn in [('unified_menu_freeflow()', 'ff', 'install_plan_ff_toggle'), ('unified_menu_reality()', 'reality', 'install_plan_reality_toggle'), ('unified_menu_vltcp()', 'vltcp', 'install_plan_vltcp_toggle'), ('unified_menu_cforigin()', 'cforigin', 'install_plan_cforigin_toggle'), ('unified_menu_socks()', 'socks', 'install_plan_socks_toggle'), ('unified_menu_http()', 'http', 'install_plan_http_toggle')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_unified_toggle_or_plan' in body and plan_fn in body, f"{body_name} runtime/install toggle should use shared toggle helper")


def test_single_file_module_uninstall_update_actions():
    for name in ['_MODULE_UNINSTALL_FN', '_MODULE_UPDATE_PORT_FN']:
        assert_true(name in TEXT, f"registry action map missing: {name}")
    for fn in ['module_ff_uninstall()', 'module_reality_uninstall()', 'module_vltcp_uninstall()', 'module_reality_update_port()', 'module_vltcp_update_port()', 'module_vlquic_update_port()', 'module_cforigin_uninstall()', 'module_cforigin_update_port()', 'module_socks_uninstall()', 'module_http_uninstall()', 'module_http_update_port()', 'module_http_update_listen()']:
        assert_true(fn in TEXT, f"module uninstall/update helper missing: {fn}")
    for body_name in ['unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_vlquic()', 'unified_menu_cforigin()', 'unified_menu_socks()', 'unified_menu_http()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_menu_confirm_uninstall' in body and '_pause; return 0' in body, f"{body_name} should provide runtime uninstall closure inside the unified workbench")


def test_single_file_module_config_update_actions():
    assert_true('_MODULE_UPDATE_LISTEN_FN' in TEXT and 'update_listen)' in TEXT, "listen updates must be registry-owned")
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_transport)', 'cforigin:update_protocol)', 'cforigin:update_path)', 'http:update_auth)', 'http:update_user)', 'http:update_pass)']:
        assert_true(token in dispatch_body, f"module_dispatch config update route missing: {token}")
    for fn in ['module_reality_update_transport()', 'module_vltcp_update_listen()', 'module_vlquic_update_listen()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_cforigin_update_listen()', 'module_http_update_auth()', 'module_http_update_user()', 'module_http_update_pass()']:
        assert_true(fn in TEXT, f"module config update helper missing: {fn}")
    assert_true('_unified_dispatch_or_plan' in TEXT and 'install_plan_cforigin_update_listen' in TEXT, "menu should route config updates through shared dispatch helper")


def test_single_file_module_argo_freeflow_actions():
    assert_true('_MODULE_ENABLE_FN' in TEXT and '_MODULE_UPDATE_PORT_FN' in TEXT, "Argo/FreeFlow common actions must be registry-owned")
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['argo:update_protocol)', 'argo:update_domain)', 'argo:update_auth)', 'ff:update_mode)', 'ff:update_host_or_path)']:
        assert_true(token in dispatch_body, f"module_dispatch Argo/FreeFlow route missing: {token}")
    for fn in ['module_argo_enable()', 'module_argo_disable()', 'module_argo_uninstall()', 'module_argo_update_protocol()', 'module_argo_update_port()', 'module_argo_update_domain()', 'module_argo_update_auth()', 'module_ff_update_mode()', 'module_ff_update_host_or_path()', 'module_ff_update_port()']:
        assert_true(fn in TEXT, f"Argo/FreeFlow action helper missing: {fn}")
    assert_true('_unified_dispatch_or_plan' in TEXT and 'install_plan_ff_update_port' in TEXT, "unified workbench should route Argo/FreeFlow actions through shared dispatch helper")


def test_single_file_module_final_complex_actions():
    dispatch_body = TEXT[TEXT.index('module_dispatch()'):TEXT.index('# 交互输入端口', TEXT.index('module_dispatch()'))]
    for token in ['reality:update_sni)', 'reality:regenerate_keys)', 'vlquic:update_cert)', 'cforigin:update_cert)', 'cforigin:update_edge_port)', 'cforigin:toggle_edge_h3)', 'cforigin:update_domain)', 'socks:update_user)', 'socks:update_pass)', 'http:update_user)', 'http:update_pass)']:
        assert_true(token in dispatch_body, f"module_dispatch final complex route missing: {token}")
    for fn in ['module_reality_update_sni()', 'module_reality_regenerate_keys()', 'module_vlquic_enable()', 'module_vlquic_disable()', 'module_vlquic_update_cert()', 'module_cforigin_update_cert()', 'module_cforigin_update_edge_port()', 'module_cforigin_toggle_edge_h3()', 'module_cforigin_update_domain()', 'module_socks_update_user()', 'module_socks_update_pass()', 'module_http_update_user()', 'module_http_update_pass()']:
        assert_true(fn in TEXT, f"final complex action helper missing: {fn}")
    assert_true('_unified_dispatch_or_plan' in TEXT and 'install_plan_vlquic_update_cert' in TEXT, "unified workbench should route final complex actions through shared helpers")

def test_single_file_manage_shells_are_dispatch_only():
    assert_true(TEXT.count('unified_menu_') >= 7, "closed-loop refactor should consolidate menus into unified workbenches")
    for legacy in ['manage_argo()', 'manage_freeflow()', 'manage_reality()', 'manage_vltcp()', 'manage_vlquic()', 'manage_cforigin()', 'manage_socks()', 'install_plan_manage_argo()', 'install_plan_manage_freeflow()', 'install_plan_manage_reality()', 'install_plan_manage_vltcp()', 'install_plan_manage_vlquic()', 'install_plan_manage_cforigin()', 'install_plan_manage_socks()']:
        assert_true(legacy not in TEXT, f"legacy wrapper should be removed after shrink phase: {legacy}")
    for legacy_ask in ['ask_argo_mode()', 'ask_argo_protocol()', 'ask_freeflow_mode()', 'ask_reality_mode()', 'ask_vltcp_mode()', 'ask_socks_mode()', 'ask_cforigin_mode()', 'ask_vlquic_mode()', 'ask_xpad_mode()']:
        assert_true(legacy_ask not in TEXT, f"legacy ask helper should be removed after shrink phase: {legacy_ask}")


def test_single_file_menu_render_helpers():
    assert_true('_menu_print_action()' in TEXT and '_menu_print_back()' in TEXT, "menu render should use shared action/back helpers")
    for body_name in ['unified_menu_argo()', 'unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_vlquic()', 'unified_menu_cforigin()', 'unified_menu_socks()', 'unified_menu_http()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('_menu_print_action' in body, f"{body_name} should use shared action renderer")
        assert_true('_menu_print_back' in body, f"{body_name} should use shared back renderer")
        assert_true('_unified_render_mode_header' in body, f"{body_name} should print the unified mode header")


def test_single_file_module_transaction_helpers():
    helper_area = TEXT[TEXT.index('_module_disable_commit()'):TEXT.index('# ==============================================================================', TEXT.index('_module_disable_commit()'))]
    assert_true('_module_enable_commit()' in helper_area and '_module_save_fields_inner()' in helper_area, "module transaction helpers missing")
    assert_true('_module_update_state_transaction()' in TEXT and '_module_update_listen_transaction()' in TEXT, "state update transaction helpers missing")
    for body_name in ['unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_cforigin()']:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true('module_dispatch' in body or '_unified_runtime_toggle' in body, f"{body_name} live actions should route through shared dispatcher/toggle helpers")
    save_body = TEXT[TEXT.index('_module_save_fields_inner()'):TEXT.index('\n}\n', TEXT.index('_module_save_fields_inner()'))]
    assert_true('_commit_inner' in save_body and 'st_persist' in save_body, "field saves should commit enabled modules and only persist disabled modules")
    assert_true('_module_save_fields()' in TEXT, "field updates should share a transaction")
    for proto in ['socks', 'http', 'vltcp', 'vlquic']:
        assert_true(f'module_update_listen_action {proto}' in TEXT, f'{proto} listen wrapper/dispatcher should delegate to canonical action')
    canonical_body = TEXT[TEXT.index('module_update_listen_action()'):TEXT.index('\n}\n', TEXT.index('module_update_listen_action()'))]
    assert_true('_module_update_listen_transaction' in canonical_body, "canonical listen action must use the transactional helper")
    for fn in ['module_reality_update_transport()', 'module_cforigin_update_protocol()', 'module_cforigin_update_path()', 'module_socks_update_user()', 'module_socks_update_pass()', 'module_http_update_user()', 'module_http_update_pass()', '_module_cforigin_save_domain()']:
        body = TEXT[TEXT.index(fn):TEXT.index('\n}\n', TEXT.index(fn))]
        assert_true('_module_save_fields' in body, f"{fn} should use the shared field transaction")

def test_protocol_links_and_udp_port_input_consistency():
    vltcp = TEXT[TEXT.index('_plg_vltcp_link()'):TEXT.index('PLUGIN_EOF', TEXT.index('_plg_vltcp_link()'))]
    assert_true('encryption=none' in vltcp, "VLESS-TCP link must include encryption=none")
    assert_true('_menu_update_port()' in TEXT, "menu port updates should use shared helper")
    assert_true('port_mgr_random_proto()' in TEXT, "random port selection should be protocol-aware")
    assert_true('_port_input=$(port_mgr_random_proto "${_proto}")' in TEXT, "empty port input should use protocol-aware random selection")
    out = run_bash("""
        source ./xray_2go.sh
        _seq=$(mktemp)
        printf '0' > "${_seq}"
        shuf() { local n; n=$(cat "${_seq}"); n=$((n + 1)); printf '%s' "${n}" > "${_seq}"; [ "${n}" -eq 1 ] && printf '443\\n' || printf '444\\n'; }
        port_mgr_in_use() { return 1; }
        port_mgr_in_use_udp() { [ "$1" = 443 ]; }
        printf 'tcp=%s udp=%s' "$(port_mgr_random_proto tcp)" "$(port_mgr_random_proto udp)"
        rm -f "${_seq}"
    """)
    assert_true(out.strip() == 'tcp=443 udp=444', "random port selection must check TCP/UDP independently")
    assert_true('module_update_port_action vlquic udp udp' in TEXT, "VLQUIC management port input must preserve UDP conflict checks")


def test_state_schema_and_plugin_permission_hardening():
    assert_true('.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888,"socks":1080,"http":1081}' in TEXT, "ports schema initialization must include cforigin, socks, and http")
    assert_true('_plugin_path_safe()' in TEXT and 'stat -c' in TEXT and '_plugin_path_safe "${PLUGIN_DIR}"' in TEXT, "plugin loader must enforce ownership/mode before source")
    assert_true('val_port "${_value}"' in TEXT and 'legacy 端口字段非法' in TEXT, "legacy port migration must validate bad values explicitly")


def test_commit_helpers_fail_closed_on_firewall_reconcile():
    result = run_bash_result(r'''
        source ./xray_2go.sh
        config_apply() { :; }
        st_persist() { :; }
        fw_reconcile() { return 1; }
        for commit in _commit_inner _module_enable_commit_inner _module_disable_commit_inner; do
            if "$commit" socks; then exit 1; fi
        done
        echo COMMIT_FAILURES_PROPAGATED
    ''')
    assert result.returncode == 0, result.stdout
    assert 'COMMIT_FAILURES_PROPAGATED' in result.stdout



def test_socks5_module_option_and_plugin_contract():
    assert_true('_plugin_write_socks()' in TEXT, "SOCKS5 built-in plugin must be installed")
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http ss2022"' in TEXT, "module registry must include socks and http")
    assert_true('[socks]="SOCKS5"' in TEXT and '[socks]=unified_menu_socks' in TEXT, "SOCKS5 registry metadata missing")
    assert_true('_MODULE_ENABLE_FN' in TEXT and '_MODULE_UPDATE_PORT_FN' in TEXT and 'module_registry_dispatch_common' in TEXT, "SOCKS5 common actions must use registry dispatch")
    for token in ['socks:update_auth)', 'socks:update_user)', 'socks:update_pass)']:
        assert_true(token in TEXT, f"SOCKS5 specialized dispatch route missing: {token}")
    for fn in ['module_socks_enable()', 'module_socks_disable()', 'module_socks_uninstall()', 'module_socks_update_port()', 'module_socks_update_listen()', 'module_socks_update_auth()', 'module_socks_update_user()', 'module_socks_update_pass()']:
        assert_true(fn in TEXT, f"SOCKS5 helper missing: {fn}")
    assert_true('"socks":   1080' in TEXT and '"socks": {' in TEXT, "state schema must include socks port/config")
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    for token in ['_plg_socks_inbound()', 'protocol:"socks"', 'auth:"password"', 'accounts:[{user:$user, pass:$pass}]', '_plg_socks_ports()', '_plg_socks_link()']:
        assert_true(token in socks_plugin, f"SOCKS5 plugin token missing: {token}")
    assert_true('module_update_port_action socks tcp' in TEXT, "SOCKS5 port update must use TCP conflict checks")

def test_socks5_link_is_generated_and_displayed():
    socks_plugin = TEXT[TEXT.index('_plugin_write_socks()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_socks()'))]
    assert_true("socks://%s@%s:%s#SOCKS5" in socks_plugin, "SOCKS plugin should generate v2rayN-compatible socks:// base64(user:pass) links")
    assert_true("base64" in socks_plugin and "tr -d '=\\n'" in socks_plugin, "SOCKS credentials must be URL-safe base64(user:pass) without padding")
    assert_true('protocol:"socks"' in socks_plugin and 'auth:"password"' in socks_plugin, "SOCKS inbound should follow reference socks password-auth implementation")



def test_http_proxy_module_option_and_plugin_contract():
    assert_true('_plugin_write_http()' in TEXT, "HTTP proxy built-in plugin must be installed")
    assert_true('[http]="HTTP 代理"' in TEXT and '[http]=unified_menu_http' in TEXT, "HTTP proxy registry metadata missing")
    assert_true('_MODULE_ENABLE_FN' in TEXT and '_MODULE_UPDATE_PORT_FN' in TEXT and 'module_registry_dispatch_common' in TEXT, "HTTP proxy common actions must use registry dispatch")
    for token in ['http:update_auth)', 'http:update_user)', 'http:update_pass)']:
        assert_true(token in TEXT, f"HTTP proxy specialized dispatch route missing: {token}")
    assert_true('"http":    1081' in TEXT and '"http": {' in TEXT, "state schema must include HTTP proxy port/config")
    http_plugin = TEXT[TEXT.index('_plugin_write_http()'):TEXT.index('_plugin_write_cforigin()', TEXT.index('_plugin_write_http()'))]
    for token in ['_plg_http_inbound()', 'protocol:"http"', 'users:[{user:$user, pass:$pass}]', 'allowTransparent:false', 'userLevel:0', '_plg_http_ports()', '_plg_http_link()']:
        assert_true(token in http_plugin, f"HTTP proxy token missing: {token}")
    assert_true('HTTP 代理为明文 TCP 协议' in TEXT, "HTTP proxy should warn that the inbound is unencrypted")

def test_install_plan_menu_is_advanced_install_entry():
    assert_true('install_plan_reset_defaults()' in TEXT, "install plan reset helper missing")
    assert_true('install_plan_render_summary()' in TEXT, "install plan summary renderer missing")
    assert_true('install_plan_validate()' in TEXT, "install plan validator missing")
    assert_true('install_execute_current_plan()' in TEXT, "shared install executor missing")
    assert_true('install_plan_menu()' in TEXT, "install plan menu missing")
    for fn in ['unified_menu_argo()', 'unified_menu_freeflow()', 'unified_menu_reality()', 'unified_menu_vltcp()', 'unified_menu_socks()', 'unified_menu_http()', 'unified_menu_vlquic()', 'unified_menu_cforigin()']:
        assert_true(fn in TEXT, f"unified install/runtime workbench missing: {fn}")
    body = TEXT[TEXT.index('module_xray_install()'):TEXT.index('\n}\n', TEXT.index('module_xray_install()'))]
    assert_true('install_plan_reset_defaults' in body, "module_xray_install should initialize the draft plan")
    assert_true('install_wizard_menu' in body, "first install should enter the deployment wizard")
    assert_true('install_plan_menu' not in body, "advanced install plan must not be the default first-install entry")
    for forbidden in ['ask_argo_mode', 'ask_freeflow_mode', 'ask_reality_mode', 'ask_vltcp_mode', 'ask_socks_mode', 'ask_vlquic_mode', 'ask_cforigin_mode']:
        assert_true(forbidden not in body, f"default install entry should not directly chain {forbidden}")
    plan_menu = TEXT[TEXT.index('install_plan_menu()'):TEXT.index('\n}\n', TEXT.index('install_plan_menu()'))]
    for marker in ['1) unified_menu_argo install', '2) unified_menu_freeflow install', '3) unified_menu_reality install', '4) unified_menu_vltcp install', '5) unified_menu_socks install', '6) unified_menu_vlquic install', '7) unified_menu_cforigin install', '10) install_plan_validate', '11)', '12) unified_menu_http install', 'install_wizard_confirm && return 0']:
        assert_true(marker in plan_menu, f"advanced install plan route missing: {marker}")


def test_deployment_wizard_gates_argo_required_inputs():
    assert_true('install_wizard_argo()' in TEXT, "Argo deployment wizard function missing")
    wizard_argo = TEXT.split('install_wizard_argo() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    for marker in ['install_plan_reset_defaults', 'install_plan_argo_toggle', 'install_plan_argo_update_protocol', 'install_wizard_require_argo_domain', 'install_wizard_require_argo_auth', 'install_plan_argo_update_auth_protocol', 'install_wizard_confirm']:
        assert_true(marker in wizard_argo, f"Argo wizard must include required step: {marker}")
    for marker in ['install_plan_argo_update_domain', 'install_plan_argo_update_auth', 'install_execute_current_plan']:
        assert_true(marker in TEXT, f"Argo required-input helper missing: {marker}")
    assert_true('install_wizard_confirm' in wizard_argo, "Argo wizard should show a final confirmation step")


def test_deployment_wizard_exposes_recommended_paths():
    assert_true('install_wizard_menu()' in TEXT, "first-install deployment wizard function missing")
    wizard = TEXT.split('install_wizard_menu() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    for marker in ['install_wizard_render', 'install_wizard_reality', 'install_wizard_argo', 'install_plan_menu']:
        assert_true(marker in wizard, f"wizard route missing: {marker}")
    for marker in ['VLESS + Reality TCP', 'Argo Tunnel', '高级自定义部署']:
        assert_true(marker in TEXT, f"wizard option label missing: {marker}")



def test_recommended_wizard_paths_reset_to_single_plan():
    reality = TEXT.split('install_wizard_reality() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    argo = TEXT.split('install_wizard_argo() {', 1)[1].split(chr(10) + '}' + chr(10), 1)[0]
    assert_true('preset_apply_reality_tcp_default' in reality, "Reality wizard should apply the single-entry preset")
    assert_true('install_plan_reset_defaults' in argo, "Argo wizard should reset a cancelled/previous draft before collecting fields")


def test_install_plan_field_level_submenus_exist_for_common_modules():
    for fn in ['install_plan_argo_toggle()', 'install_plan_argo_update_protocol()', 'install_plan_argo_update_port()', 'install_plan_argo_update_domain()', 'install_plan_argo_update_auth()', 'install_plan_argo_toggle_xpad()', 'install_plan_ff_toggle()', 'install_plan_ff_update_mode()', 'install_plan_ff_update_port()', 'install_plan_ff_update_host_or_path()', 'install_plan_ff_toggle_xpad()', 'install_plan_reality_toggle()', 'install_plan_reality_update_port()', 'install_plan_reality_update_sni()', 'install_plan_reality_update_transport()', 'install_plan_reality_toggle_xpad()', 'install_plan_vltcp_toggle()', 'install_plan_vltcp_update_port()', 'install_plan_vltcp_update_listen()', 'install_plan_socks_toggle()', 'install_plan_socks_update_port()', 'install_plan_socks_update_listen()', 'install_plan_socks_update_user()', 'install_plan_socks_update_pass()', 'install_plan_http_toggle()', 'install_plan_http_update_port()', 'install_plan_http_update_listen()', 'install_plan_http_update_user()', 'install_plan_http_update_pass()', 'install_plan_vlquic_toggle()', 'install_plan_vlquic_update_port()', 'install_plan_vlquic_update_listen()', 'install_plan_vlquic_update_cert()', 'install_plan_cforigin_toggle()', 'install_plan_cforigin_update_protocol()', 'install_plan_cforigin_update_domain()', 'install_plan_cforigin_update_path()', 'install_plan_cforigin_update_edge_port()', 'install_plan_cforigin_update_origin_port()', 'install_plan_cforigin_update_listen()', 'install_plan_cforigin_toggle_edge_h3()', 'install_plan_cforigin_update_cert()']:
        assert_true(fn in TEXT, f"field-level install helper missing: {fn}")
    for body_name, marker in [('unified_menu_argo()', 'Argo 闭环工作台'), ('unified_menu_freeflow()', 'FreeFlow 闭环工作台'), ('unified_menu_reality()', 'Reality 闭环工作台'), ('unified_menu_vltcp()', 'VLESS-TCP 闭环工作台'), ('unified_menu_vlquic()', 'VLESS-XHTTP-H3 闭环工作台'), ('unified_menu_cforigin()', 'CF Origin 闭环工作台'), ('unified_menu_socks()', 'SOCKS5 闭环工作台'), ('unified_menu_http()', 'HTTP 代理闭环工作台')]:
        body = TEXT[TEXT.index(body_name):TEXT.index('\n}\n', TEXT.index(body_name))]
        assert_true(marker in body and '_runtime=0' in body, f"unified workbench marker missing for {body_name}")

def test_interactive_menu_copy_is_guided_and_consistent():
    assert_true('_menu_print_action 0 "返回上一级"' in TEXT, "submenu back label should say return to upper level")
    assert_true('Xray-2go 控制台' in TEXT, "main menu title should be localized")
    assert_true('开始部署（快速向导）' in TEXT, "main menu install copy should name the guided deployment entry")
    assert_true('快速部署向导' in TEXT and '高级自定义部署' in TEXT, "first-install path should expose guided and advanced modes")
    for token in ['进入 Reality 配置页', '运行安装前检查', '预览并确认安装', 'prompt "请选择部署方案 (0-3，回车选 1): " _c', '确认开始部署？(y/N): ', '请选择操作 $( [ "${_runtime}" -eq 1 ] && printf', '返回上一级']:
        assert_true(token in TEXT, f"interactive menu copy token missing: {token}")


def test_cli_reality_tcp_preset_entry_exists_and_uses_shared_executor():
    for fn in ['usage()', 'parse_args()', 'cli_install()', 'cli_dispatch()', 'preset_apply_reality_tcp_default()', 'reality_pick_default_tcp_port()']:
        assert_true(fn in TEXT, f"CLI helper missing: {fn}")
    parse_body = TEXT[TEXT.index('parse_args()'):TEXT.index('\n}\n', TEXT.index('parse_args()'))]
    for token in ['_CLI_ACTION="menu"', '_CLI_REALITY_PORT=""', '[ "$#" -eq 0 ] && return 0', 'reality)', '-p)', '-p 需要端口值', '未知参数: $1']:
        assert_true(token in parse_body, f"parse_args token missing: {token}")
    cli_install_body = TEXT[TEXT.index('cli_install()'):TEXT.index('\n}\n', TEXT.index('cli_install()'))]
    for token in ['preset_apply_reality_tcp_default', '_CLI_REALITY_PORT', 'install_execute_current_plan']:
        assert_true(token in cli_install_body, f"cli_install token missing: {token}")
    preset_body = TEXT[TEXT.index('preset_apply_reality_tcp_default()'):TEXT.index('\n}\n', TEXT.index('preset_apply_reality_tcp_default()'))]
    for token in ['local _port _explicit_port', 'val_port "${_explicit_port}"', '.reality.enabled = true', '.reality.network = "tcp"', '.argo.enabled = false', '.ff.enabled = false', '.vltcp.enabled = false', '.socks.enabled = false', '.vlquic.enabled = false', '.cforigin.enabled = false']:
        assert_true(token in preset_body, f"reality tcp preset missing: {token}")
    assert_true('reality_pick_default_tcp_port' in preset_body and '.ports.reality = ($p|tonumber)' in preset_body, "reality preset should set port through helper or explicit override")
    pick_body = TEXT[TEXT.index('reality_pick_default_tcp_port()'):TEXT.index('\n}\n', TEXT.index('reality_pick_default_tcp_port()'))]
    for token in ['local _preferred=443', 'port_mgr_in_use "${_preferred}"', 'port_mgr_random_proto tcp', '自动改用随机端口']:
        assert_true(token in pick_body, f"reality default port helper token missing: {token}")
    main_body = TEXT[TEXT.index('main()'):TEXT.index('if [ "${BASH_SOURCE[0]}" = "$0" ]; then', TEXT.index('main()'))]
    assert_true('parse_args "$@"' in main_body and 'cli_dispatch' in main_body, "main should route through cli_dispatch")
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        parse_args reality -p 2443
        printf 'alias_action=%s port_override=%s\n' "${_CLI_ACTION}" "${_CLI_REALITY_PORT}"
        preset_apply_reality_tcp_default "${_CLI_REALITY_PORT}"
        printf 'argo=%s reality=%s net=%s ff=%s socks=%s vlquic=%s cforigin=%s port=%s\n' \
            "$(st_get '.argo.enabled')" "$(st_get '.reality.enabled')" "$(st_get '.reality.network')" \
            "$(st_get '.ff.enabled')" "$(st_get '.socks.enabled')" "$(st_get '.vlquic.enabled')" \
            "$(st_get '.cforigin.enabled')" "$(port_of reality)"
    """)
    assert_true('alias_action=install port_override=2443' in out, "reality -p should enter install mode and persist explicit port override")
    assert_true('reality=true net=tcp' in out and 'port=2443' in out, "reality tcp preset should apply the explicit port override")


def test_reality_preset_auto_random_port_when_443_busy():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        port_mgr_in_use() { [ "$1" = 443 ]; }
        port_mgr_random_proto() { printf '23456'; }
        preset_apply_reality_tcp_default
        printf 'port=%s\n' "$(port_of reality)"
    """)
    assert_true('port=23456' in out, "reality preset should auto-switch to random high port when 443 is busy")


def test_cli_reality_port_option_requires_valid_value():
    out = run_bash("""
        source ./xray_2go.sh
        parse_args reality -p 2443
        printf 'ok=%s\n' "${_CLI_REALITY_PORT}"
    """)
    assert_true('ok=2443' in out, 'reality -p should accept a valid explicit port')

    try:
        run_bash("source ./xray_2go.sh; parse_args reality -p")
        raise AssertionError('parse_args reality -p should fail without a value')
    except subprocess.CalledProcessError as e:
        assert_true('-p 需要端口值' in e.stdout, 'reality -p without value should fail with a clear error')

    try:
        run_bash("source ./xray_2go.sh; parse_args reality -p abc")
        raise AssertionError('parse_args reality -p abc should fail')
    except subprocess.CalledProcessError as e:
        assert_true('非法端口' in e.stdout or '端口' in e.stdout, 'reality -p should validate port format')


def test_socks_runtime_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "fw_reconcile() { :; }; "
                "config_print_nodes() { :; }; "
                "module_socks_action enable; "
                "printf 'after_enable=%s\\n' \"$(st_get '.socks.enabled')\"; "
                "module_socks_action disable; "
                "printf 'after_disable=%s\\n' \"$(st_get '.socks.enabled')\"; "
                "module_socks_action() { printf 'dispatcher_action=%s\\n' \"$1\"; }; "
                "module_dispatch socks enable",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical SOCKS action failed: {cp.stdout}")
    assert_true("after_enable=true" in cp.stdout, "canonical SOCKS action must enable the module")
    assert_true("after_disable=false" in cp.stdout, "canonical SOCKS action must disable the module")
    assert_true("dispatcher_action=enable" in cp.stdout, "dispatcher must route SOCKS enable to canonical action")


def test_runtime_port_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "fw_reconcile() { :; }; "
                "config_print_nodes() { :; }; "
                "port_mgr_in_use() { return 1; }; "
                "prompt() { printf -v \"$2\" '%s' 2443; }; "
                "module_update_port_action reality tcp; "
                "printf 'reality=%s\\n' \"$(port_of reality)\"; "
                "module_update_port_action() { printf 'dispatcher_port=%s/%s\\n' \"$1\" \"$2\"; }; "
                "module_dispatch vltcp update_port",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime port action failed: {cp.stdout}")
    assert_true("reality=2443" in cp.stdout, "canonical port action must update the requested port")
    assert_true("dispatcher_port=vltcp/tcp" in cp.stdout, "dispatcher must route update_port to canonical action")


def test_runtime_listen_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "mkdir -p \"${WORK_DIR}\"; "
                "st_init; "
                "config_apply() { :; }; "
                "st_persist() { :; }; "
                "prompt() { printf -v \"$2\" '%s' 127.0.0.1; }; "
                "module_update_listen_action vltcp; "
                "printf 'vltcp=%s\\n' \"$(st_get '.vltcp.listen')\"; "
                "module_update_listen_action() { printf 'dispatcher_listen=%s\\n' \"$1\"; }; "
                "module_dispatch socks update_listen",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime listen action failed: {cp.stdout}")
    assert_true("vltcp=127.0.0.1" in cp.stdout, "canonical listen action must update the requested address")
    assert_true("dispatcher_listen=socks" in cp.stdout, "dispatcher must route update_listen to canonical action")


def test_runtime_show_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "config_print_nodes() { printf 'nodes\\n'; }; "
                "cforigin_print_cloudflare_hint() { printf 'cforigin_hint\\n'; }; "
                "module_show_action cforigin; "
                "module_show_action() { printf 'dispatcher_show=%s\\n' \"$1\"; }; "
                "module_dispatch reality show",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical runtime show action failed: {cp.stdout}")
    assert_true("nodes" in cp.stdout and "cforigin_hint" in cp.stdout, "canonical show action must preserve CF Origin hint output")
    assert_true("dispatcher_show=reality" in cp.stdout, "dispatcher must route show to canonical action")


def test_runtime_argo_field_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh; "
                "set -e; "
                "module_argo_update_action() { printf 'argo_action=%s\\n' \"$1\"; }; "
                "module_dispatch argo update_protocol; "
                "module_dispatch argo update_auth_protocol; "
                "module_dispatch argo update_trojan_password; "
                "module_dispatch argo update_domain; "
                "module_dispatch argo update_auth",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo field dispatcher failed: {cp.stdout}")
    for action in ["protocol", "auth_protocol", "trojan_password", "domain", "auth"]:
        assert_true(f"argo_action={action}" in cp.stdout, f"Argo dispatcher must route {action} to canonical owner: {cp.stdout}")


def test_runtime_enable_paths_no_longer_depend_on_removed_ask_helpers():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        config_apply() { return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        cforigin_print_cloudflare_hint() { :; }
        config_print_nodes() { :; }
        module_dispatch ff enable
        printf 'ff=%s proto=%s\n' "$(st_get '.ff.enabled')" "$(st_get '.ff.protocol')"
        module_dispatch socks enable
        printf 'socks=%s\n' "$(st_get '.socks.enabled')"
        st_set '.cforigin.domain = "example.com" | .cforigin.cert = $cert | .cforigin.key = $key' \
            --arg cert "${WORK_DIR}/cert.pem" --arg key "${WORK_DIR}/key.pem" >/dev/null
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=example.com \
            -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" >/dev/null 2>&1
        module_dispatch cforigin enable
        printf 'cforigin=%s proto=%s path=%s\n' "$(st_get '.cforigin.enabled')" "$(st_get '.cforigin.protocol')" "$(st_get '.cforigin.path')"
        rm -f "${WORK_DIR}/cert.pem" "${WORK_DIR}/key.pem"
    """)
    assert_true('ff=true proto=ws' in out, 'ff enable should no longer depend on removed ask_* helpers and should seed default protocol')
    assert_true('socks=true' in out, 'socks enable should no longer depend on removed ask_* helpers')
    assert_true('cforigin=true proto=ws path=/origin' in out, 'cforigin enable should no longer depend on removed ask_* helpers and should seed defaults')


def test_runtime_dispatch_supports_reality_and_vltcp_update_port():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        config_apply() { return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        prompt() { printf -v "$2" '%s' 2443; }
        module_dispatch reality update_port
        printf 'reality=%s\n' "$(port_of reality)"
        prompt() { printf -v "$2" '%s' 15555; }
        module_dispatch vltcp update_port
        printf 'vltcp=%s\n' "$(port_of vltcp)"
    """)
    assert_true('reality=2443' in out, 'runtime dispatch should support reality update_port')
    assert_true('vltcp=15555' in out, 'runtime dispatch should support vltcp update_port')


def test_install_plan_argo_auth_is_state_only_before_execution():
    out = run_bash("""
        source ./xray_2go.sh
        st_init
        rm -f "${WORK_DIR}/tunnel.json"
        prompt_secret() {
            printf '%s' '{"TunnelSecret":"abc","TunnelID":"11111111-1111-1111-1111-111111111111"}'
            printf -v "$2" '%s' '{"TunnelSecret":"abc","TunnelID":"11111111-1111-1111-1111-111111111111"}'
        }
        install_plan_argo_update_auth
        printf 'cred_b64=%s token=%s file=%s\n' "$(st_get '.argo.cred_b64')" "$(st_get '.argo.token')" "$( [ -f "${WORK_DIR}/tunnel.json" ] && printf yes || printf no )"
        rm -f "${WORK_DIR}/tunnel.json"
    """)
    assert_true('file=no' in out, 'install-plan argo auth editing must not create tunnel.json before execution')
    assert_true('cred_b64=' in out and 'token=' in out, 'install-plan argo auth should persist state fields')


def test_install_prepares_argo_before_starting_tunnel():
    start = TEXT.index('module_xray_install_core()')
    body = TEXT[start:TEXT.index('\n}\n', start)]
    prepare = body.index('_argo_prepare_fixed_tunnel_from_state && svc_apply_tunnel')
    launch = body.index('svc_enable_start_verify "${_SVC_TUNNEL}"')
    persist = body.index('st_persist ||')
    assert_true(prepare < launch < persist, 'prepare Tunnel, verify startup, then commit state')


def test_state_get_preserves_false_and_zero_values():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false | .ports.argo = 0' >/dev/null
        printf 'enabled=%s port=%s\\n' "$(st_get '.argo.enabled')" "$(st_get '.ports.argo')"
    """)
    assert_true(cp.returncode == 0, "state probe should complete")
    assert_true("enabled=false" in cp.stdout and "port=0" in cp.stdout, "state reads must preserve false and zero")


def test_runtime_edits_use_locked_enablement_and_split_prerequisites():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.socks.enabled=false | .argo.enabled=true | .argo.protocol="xhttp" |
            .argo.auth_protocol="vless" | .reality.enabled=true | .reality.pvk="fixture"'
        st_persist
        config_apply() { printf '%s\n' "$(st_get '.socks.listen')" > "$WORK_DIR/applied"; }
        config_print_nodes() { return 0; }
        prompt() {
            (st_set '.socks.enabled=true | .reality.enabled=false' && st_persist) || return 1
            printf -v "$2" '%s' 127.0.0.1
        }
        module_socks_update_listen
        [[ $(<"$WORK_DIR/applied") == 127.0.0.1 ]]
        profile='{"mode":"packet-up","split":{"port":39198}}'
        if _argo_xhttp_set_profile 1 "$profile"; then exit 1; fi
        [[ -z $(st_get '.argo.xhttp.split.port') ]]
        st_set '.argo.xhttp.split.port=39198'
        st_persist
        touch "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        port_mgr_in_use() { [[ $1 == 39198 ]]; }
        if module_reality_enable; then exit 1; fi
        [[ $(st_get '.reality.enabled') == false ]]
        port_mgr_in_use() { return 1; }
        fw_reconcile() { return 0; }
        module_reality_enable
        _argo_xhttp_split_active
    ''', timeout=45)


def test_failed_firewall_cleanup_restores_module_and_keeps_rule_record():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.socks.enabled = true'
        st_persist
        printf 'original' > "$CONFIG_FILE"
        printf 'ufw:1080/tcp\n' > "$_FW_RULES_FILE"
        config_apply() { printf 'changed' > "$CONFIG_FILE"; }
        fw_desired_rules() { return 0; }
        _fw_select_backend() { printf ufw; }
        ufw() {
            if [[ $1 == status ]]; then
                printf 'Status: active\n1080/tcp ALLOW IN Anywhere\n39091/tcp ALLOW IN Anywhere\n'
            else
                return 1
            fi
        }
        if module_dispatch socks disable; then exit 1; fi
        [[ $(st_get '.socks.enabled') == true && $(<"$CONFIG_FILE") == original ]]
        jq -e '.socks.enabled == true' "$STATE_FILE" >/dev/null
        grep -qx 'ufw:1080/tcp' "$_FW_RULES_FILE"
        add_rule_and_fail() { _fw_mark_rule ufw 39091 tcp; return 1; }
        if _transaction_run 'fixture' add_rule_and_fail; then exit 1; fi
        grep -qx 'ufw:39091/tcp' "$_FW_RULES_FILE"
    ''')


def test_transaction_rollback_preserves_normalized_state():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$WORK_DIR"
        printf '{}' > "$STATE_FILE"
        st_init
        before=$(st_get '.uuid')
        [[ -n $before ]]
        fail_edit() { st_set '.uuid = "failed-edit"'; return 1; }
        if _transaction_run 'fixture' fail_edit; then exit 1; fi
        [[ $(st_get '.uuid') == "$before" && $(<"$STATE_FILE") == '{}' ]]
    ''')


def test_cforigin_rejects_hostname_drift_and_mismatched_private_key():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "$WORK_DIR"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=old.fixture.invalid \
            -addext 'subjectAltName=DNS:old.fixture.invalid,DNS:alias.fixture.invalid' \
            -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" >/dev/null 2>&1
        st_init
        st_set '.cforigin += {domain:"old.fixture.invalid",origin_tls:true,cert:$cert,key:$key}' \
            --arg cert "$WORK_DIR/cert.pem" --arg key "$WORK_DIR/key.pem"
        st_persist
        prompt() { printf -v "$2" '%s' "$candidate"; }
        candidate=uncovered.fixture.invalid
        if module_cforigin_update_domain; then exit 1; fi
        [[ $(st_get '.cforigin.domain') == old.fixture.invalid ]]
        candidate=alias.fixture.invalid
        module_cforigin_update_domain
        [[ $(st_get '.cforigin.domain') == alias.fixture.invalid ]]
        openssl genpkey -algorithm ED25519 -out "$WORK_DIR/wrong.pem" 2>/dev/null
        st_set '.cforigin.key = $key' --arg key "$WORK_DIR/wrong.pem"
        if _cforigin_check_ready; then exit 1; fi
    ''')


def test_managed_certificates_survive_module_removal_and_are_cleaned_on_uninstall():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        legacy="$_CERT_DIR/legacy.fixture.invalid"
        issued="$_CERT_DIR/issued.fixture.invalid"
        imported="$_CERT_DIR/imported.fixture.invalid"
        mkdir -p "$legacy" "$issued" "$imported" "$HOME/.acme.sh"
        for dir in "$legacy" "$issued" "$imported"; do
            printf cert > "$dir/fullchain.pem"
            printf key > "$dir/privkey.pem"
        done
        printf independent > "$legacy/notes"
        printf '#!/bin/sh\nexit 0\n' > "$HOME/.acme.sh/acme.sh"
        chmod +x "$HOME/.acme.sh/acme.sh"
        st_set '.vlquic += {enabled:true, domain:"legacy.fixture.invalid", acme_method:"http01", cert:($d+"/fullchain.pem"), key:($d+"/privkey.pem")}' --arg d "$legacy"
        atomic_write_secret "$STATE_FILE" "$_G_STATE"
        st_init
        config_apply() { :; }
        fw_reconcile() { :; }
        module_vlquic_uninstall
        [[ -f "$legacy/fullchain.pem" && -f "$legacy/privkey.pem" ]]
        acme_install_cert_to_state cforigin issued.fixture.invalid dns_cf_token
        acme_install_cert issued.fixture.invalid http01
        st_persist
        module_vlquic_uninstall
        module_cforigin_uninstall
        [[ -f "$issued/fullchain.pem" && -f "$issued/privkey.pem" ]]
        st_set '.cforigin += {domain:"imported.fixture.invalid", acme_method:"manual", cert:($d+"/fullchain.pem"), key:($d+"/privkey.pem")}' --arg d "$imported"
        st_persist
        _uninstall_managed_files
        _uninstall_managed_files
        [[ ! -e "$legacy/fullchain.pem" && ! -e "$legacy/privkey.pem" && -f "$legacy/notes" ]]
        [[ ! -e "$issued" && -f "$imported/fullchain.pem" && -f "$imported/privkey.pem" ]]
    ''')


def test_uninstall_retries_failed_firewall_and_preserves_external_files():
    cp = run_bash_result(r"""
        source ./xray_2go.sh
        mkdir -p "$WORK_DIR" "$(dirname "$SELF_DEST")" "$HOME/.cloudflared"
        printf '%s\n' 'ufw:39091/tcp' > "$_FW_RULES_FILE"
        printf fixture > "$SELF_DEST"
        printf fixture > "$CONFIG_FILE"
        printf external > "$HOME/.cloudflared/independent.json"
        printf external > "$WORK_DIR/imported.pem"
        mkdir -p "$PLUGIN_DIR" "$_CERT_DIR/issued.fixture.invalid"
        printf '# xray-2go plugin: argo\n' > "$PLUGIN_DIR/argo.sh"
        printf '# independent plugin\n' > "$PLUGIN_DIR/custom.sh"
        printf managed > "$_CERT_DIR/issued.fixture.invalid/fullchain.pem"
        printf managed > "$_CERT_DIR/issued.fixture.invalid/privkey.pem"
        st_init || exit 1
        st_set '.cforigin += {acme_method:"dns_cf_token",domain:"issued.fixture.invalid",cert:($dir+"/fullchain.pem"),key:($dir+"/privkey.pem")}' \
            --arg dir "$_CERT_DIR/issued.fixture.invalid" || exit 1
        st_persist || exit 1
        prompt() { printf -v "$2" y; }
        svc_exec_mut() { return 0; }
        is_systemd() { return 1; }
        ufw() {
            case "$1" in
                status) printf 'Status: active\n'; [[ -n ${deleted:-} ]] || printf '39091/tcp ALLOW IN Anywhere\n' ;;
                --force) [[ $2 == delete && -n ${retry:-} ]] || return 1; deleted=1 ;;
            esac
            return 0
        }
        if module_xray_uninstall; then exit 1; fi
        grep -qx 'ufw:39091/tcp' "$_FW_RULES_FILE" || exit 1
        [[ -f $SELF_DEST && -f $CONFIG_FILE && -f $_UNINSTALL_PENDING ]] || exit 1
        install_plan_validate() { return 0; }
        module_xray_install_core() { touch "$WORK_DIR/unexpected-install"; return 1; }
        if install_execute_current_plan; then exit 1; fi
        [[ ! -e $WORK_DIR/unexpected-install ]] || exit 1
        retry=1
        module_xray_uninstall || exit 1
        [[ ! -e $SELF_DEST && ! -e $_FW_RULES_FILE && ! -e $CONFIG_FILE ]] || exit 1
        [[ -f $HOME/.cloudflared/independent.json && -f $WORK_DIR/imported.pem ]] || exit 1
        [[ -f $PLUGIN_DIR/custom.sh && ! -e $PLUGIN_DIR/argo.sh && ! -d $_CERT_DIR/issued.fixture.invalid ]] || exit 1
    """)
    assert_true(cp.returncode == 0, cp.stdout)


def test_first_deploy_rejects_existing_or_stale_plan_before_install_core():
    cp = run_bash_result(r"""
        source ./xray_2go.sh
        st_init || exit 1
        st_persist || exit 1
        preset_apply_reality_tcp_default() { return 0; }
        install_plan_validate() { return 0; }
        module_xray_install_core() { printf 'UNEXPECTED_INSTALL\n'; return 1; }
        printf 'existing config' > "$CONFIG_FILE"
        if cli_install; then exit 1; fi
        [[ $(<"$CONFIG_FILE") == 'existing config' ]] || exit 1
        rm -f -- "$CONFIG_FILE"
        (st_set '.ports.reality = 39091' && st_persist) || exit 1
        if cli_install; then exit 1; fi
    """)
    assert_true(cp.returncode == 0 and "UNEXPECTED_INSTALL" not in cp.stdout, cp.stdout)


def test_binary_alone_does_not_block_first_deploy():
    cp = run_bash_result(r"""
        source ./xray_2go.sh
        mkdir -p "$(dirname "$XRAY_BIN")" || exit 1
        printf 'binary fixture' > "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        is_systemd() { return 1; }
        if check_xray_install; then exit 1; fi
    """)
    assert_true(cp.returncode == 0, cp.stdout)


def test_first_deploy_refresh_failure_keeps_reusable_binary():
    cp = run_bash_result(r"""
        source ./xray_2go.sh
        st_init || exit 1
        mkdir -p "$(dirname "$XRAY_BIN")" || exit 1
        printf 'binary fixture' > "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        is_systemd() { return 1; }
        platform_preflight() { return 0; }
        install_plan_validate() { return 0; }
        plugin_refresh_runtime() { return 1; }
        if install_execute_current_plan; then exit 1; fi
        [[ -x $XRAY_BIN && ! -e $CONFIG_FILE ]] || exit 1
    """)
    assert_true(cp.returncode == 0, cp.stdout)

def test_install_plan_rejects_unconfigured_argo():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        plugin_refresh_runtime || exit 1
        install_plan_validate
    """)
    assert_true(cp.returncode != 0, "an enabled but unconfigured Argo plan must fail validation")
    assert_true("Argo" in cp.stdout and ("域名" in cp.stdout or "token" in cp.stdout), "Argo validation should explain the missing configuration")


def test_install_completion_only_reports_success_after_core_commit():
    cp = run_bash_result(r'''
        source ./xray_2go.sh
        install_plan_validate() { return 0; }
        module_xray_install_core() { return 1; }
        if install_execute_current_plan; then exit 1; fi
        module_xray_install_core() { echo 'state committed'; }
        config_print_nodes() { return 0; }
        cforigin_print_cloudflare_hint() { :; }
        prompt() { printf -v "$2" 'y'; }
        install_execute_current_plan interactive
    ''')
    assert_true(cp.returncode == 0, cp.stdout)
    assert_true(cp.stdout.count('安装完成，服务已启动') == 1, cp.stdout)
    assert_true(cp.stdout.index('state committed') < cp.stdout.index('安装完成，服务已启动'), cp.stdout)
    assert_true('客户端连接已由你确认' in cp.stdout, cp.stdout)


def test_wizard_default_previews_ports_before_confirming_install():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        _PLUGIN_REGISTRY=(reality)
        _plg_reality_ports() { port_of reality; }
        _plg_reality_link() { :; }
        _plg_reality_inbound() { :; }
        port_mgr_in_use() { return 1; }
        clear() { :; }
        install_execute_current_plan() { echo 'install invoked'; }
        prompt() {
            case "$1" in
                请选择部署方案*) printf -v "$2" '' ;;
                确认开始部署*) printf -v "$2" 'y' ;;
                *) return 1 ;;
            esac
        }
        install_wizard_menu
    ''')
    assert_true(out.index('443/tcp') < out.index('install invoked'), out)


def test_apt_dependency_retries_with_refreshed_index():
    out = run_bash(r'''
        source ./xray_2go.sh
        refreshed=0
        find() { return 0; }
        apt-get() {
            case "$1" in
                install)
                    printf '%s
' 'apt install' >&2
                    if [ "$refreshed" = 0 ]; then
                        printf '%s\n' 'E: fixture package download returned 404' >&2
                        return 100
                    fi
                    fixture_dependency() { :; }
                    ;;
                update)
                    printf '%s\n' 'apt update' >&2
                    refreshed=1
                    ;;
                *) return 2 ;;
            esac
        }
        platform_pkg_require fixture_dependency || exit 1
        platform_pkg_require fixture_dependency
    ''')
    assert_true('E: fixture package download returned 404' in out, out)
    assert_true(out.count('apt install') == 2 and out.count('apt update') == 1, out)
    assert_true(out.count('fixture_dependency 已就绪') == 1, out)


def test_optional_dependency_failure_does_not_abort_preflight():
    out = run_bash(r'''
        source ./xray_2go.sh
        command() {
            if [ "$1" = '-v' ] && [ "$2" = xxd ]; then return 1; fi
            if [ "$1" = '-v' ] && [ "$2" = apt-get ]; then return 0; fi
            builtin command "$@"
        }
        curl() { :; }
        unzip() { :; }
        jq() { :; }
        apt-get() { return 100; }
        platform_preflight
    ''')
    assert_true('xxd 未安装' in out and '依赖预检通过' in out, out)


def test_required_dependency_failure_stops_before_state_setup():
    cp = run_bash_result(r'''
        source ./xray_2go.sh
        check_root() { :; }
        platform_detect_os() { :; }
        platform_detect_init() { :; }
        platform_detect_arch() { :; }
        platform_pkg_require() {
            printf 'dependency=%s\n' "$1"
            [ "$1" != unzip ]
        }
        st_init() { printf '%s\n' 'state setup called'; }
        main
    ''')
    assert_true(cp.returncode != 0, cp.stdout)
    assert_true('dependency=unzip' in cp.stdout, cp.stdout)
    assert_true('dependency=jq' not in cp.stdout and 'state setup called' not in cp.stdout, cp.stdout)


def test_argo_xhttp_profiles_and_shared_reality_inbound():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        platform_get_realip() { printf '%s\n' '203.0.113.5'; }
        st_set '.argo.enabled=true | .argo.protocol="xhttp" | .argo.domain="argo.example.com" |
            .cfip="edge.example.com" | .cfport=8443 |
            .reality.enabled=true | .reality.sni="target.example.com" | .reality.sid="0123456789abcdef" |
            .reality.pbk="fixture_public_key" | .reality.pvk="fixture_private_key"'
        plugin_refresh_runtime
        links=$(plugin_collect_links argo)
        [[ "$links" == *Argo-XHTTP* && "$links" != *Argo-XHTTP-Split* ]]
        _argo_xhttp_set_profile 0 '{"server":{},"client":{}}'
        links=$(plugin_collect_links argo)
        [[ "$links" != *extra=* ]]
        _argo_xhttp_set_profile 0 '{"server":{"xPaddingBytes":"200-500"},"client":{"xmux":{"maxConcurrency":1}},"split":{"port":28443,"download":{"xhttpSettings":{"extra":{"xmux":{"maxConnections":2}}}}}}'
        config_build_inbounds | jq -e --argjson origin "$(port_of argo)" '
            any(.[]; .port == $origin and .listen == "127.0.0.1" and .streamSettings.xhttpSettings.mode == "auto"
              and .streamSettings.xhttpSettings.extra.xPaddingBytes == "200-500") and
            any(.[]; .port == 28443 and .streamSettings.security == "reality" and .settings.fallbacks[0].dest == ("127.0.0.1:" + ($origin|tostring))) and
            any(.[]; .streamSettings.security == "reality" and .settings.clients[0].flow == "xtls-rprx-vision")' >/dev/null
        fw_desired_rules | grep -qx 28443/tcp
        _argo_xhttp_client_stream split | jq -e '
            .security == "reality" and .realitySettings.password == "fixture_public_key" and
            .xhttpSettings.extra.xmux.maxConcurrency == 1 and
            .xhttpSettings.extra.downloadSettings.security == "tls" and
            .xhttpSettings.extra.downloadSettings.tlsSettings.serverName == "argo.example.com" and
            .xhttpSettings.extra.downloadSettings.xhttpSettings.extra.xPaddingBytes == "200-500" and
            .xhttpSettings.extra.downloadSettings.xhttpSettings.extra.xmux.maxConnections == 2' >/dev/null
        links=$(plugin_collect_links argo)
        [[ "$links" == *Argo-XHTTP-Split* && "$links" != *fixture_private_key* ]]
        printf '%s\n' "$links" | python3 -c '
import json, sys
from urllib.parse import parse_qs, urlsplit
links = [urlsplit(line.strip()) for line in sys.stdin if line.strip()]
normal = next(link for link in links if link.fragment == "Argo-XHTTP")
split = next(link for link in links if link.fragment == "Argo-XHTTP-Split")
ordinary = parse_qs(normal.query)
separated = parse_qs(split.query)
assert "downloadSettings" not in json.loads(ordinary["extra"][0])
assert split.hostname == "203.0.113.5" and split.port == 28443
assert separated["mode"] == ["packet-up"] and separated["security"] == ["reality"]
assert separated["sni"] == ["target.example.com"] and separated["pbk"] == ["fixture_public_key"]
assert ordinary["security"] == ["tls"] and normal.hostname == "edge.example.com"
assert json.loads(separated["extra"][0])["downloadSettings"]["port"] == 8443
'
        st_set '.reality.sid="abcdef"'
        _argo_xhttp_client_stream split | jq -e '.realitySettings.shortId == "abcdef"' >/dev/null
        _argo_xhttp_set_profile 0 '{"split":{"port":28443}}'
        _argo_xhttp_set_profile 0 '{"split":{"port":28443,"download":{"address":"","port":null,"network":null,"security":null,"xhttpSettings":{"path":null}}}}'
        _argo_xhttp_export_json split | jq -e '
            (.settings.vnext[0] | .address == "203.0.113.5" and .port == 28443) and
            (.streamSettings.xhttpSettings.extra.downloadSettings |
                .address == "edge.example.com" and .port == 8443 and .network == "xhttp" and .security == "tls" and
                .xhttpSettings.path == "/argo" and .xhttpSettings.host == "argo.example.com" and
                .tlsSettings.serverName == "argo.example.com" and (has("realitySettings") | not))' >/dev/null
        _argo_xhttp_set_profile 0 '{"split":{"port":28443,"download":{"address":"[2001:db8::5]","port":28444,"xhttpSettings":{"path":"/custom"}}}}'
        _argo_xhttp_export_json split | jq -e '.streamSettings.xhttpSettings.extra.downloadSettings |
            .address == "2001:db8::5" and .port == 28444 and .xhttpSettings.path == "/custom"' >/dev/null
        _argo_xhttp_set_profile 0 '{"split":{"port":28443,"download":{"security":"reality"}}}' && exit 1
        st_set '.argo.xhttp.split.download = {security:"reality",realitySettings:{publicKey:"legacy-key"}}'
        platform_get_realip() { printf '%s\n' '2001:db8::10'; }
        _argo_xhttp_export_json split | jq -e '
            .settings.vnext[0].address == "2001:db8::10" and
            (.streamSettings.xhttpSettings.extra.downloadSettings |
                .address == "edge.example.com" and .security == "tls" and (has("realitySettings") | not))' >/dev/null
        [[ "$(_argo_xhttp_link split)" == *"@[2001:db8::10]:28443?"* ]]
        prompt() { IFS= read -r "$2"; }
        _pause() { :; }
        _xhttp_edit_field argo 0 split.mode '模式' <<< stream-up
        jq -e '.argo.xhttp.split | .mode == "stream-up" and .download == {}' <<< "${_G_STATE}" >/dev/null
        _argo_xhttp_set_profile 0 '{"split":{"port":28443,"mode":"stream-one"}}' && exit 1
        _argo_xhttp_set_profile 0 '{"client":{"xmux":{"maxConcurrency":"1-2","maxConnections":3}}}' && exit 1
        st_set '.reality.enabled=false'
        [[ "$(plugin_collect_links argo)" != *Argo-XHTTP-Split* ]]
        [[ "$(fw_desired_rules)" != *28443/tcp* ]]
        printf '%s\n' 'Argo XHTTP profiles verified'
    ''', timeout=42)
    assert_true('Argo XHTTP profiles verified' in out, out)


def test_argo_transport_changes_reconcile_split_listener():
    output = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled=true | .argo.protocol="xhttp" | .argo.domain="tunnel.fixture.invalid" |
            .argo.token="fixture" | .argo.xhttp={split:{port:28443}} |
            .reality.enabled=true | .reality.pvk="fixture-private" | .reality.pbk="fixture-public" |
            .reality.sid="01234567"'
        st_persist
        plugin_refresh_runtime
        platform_get_realip() { printf 192.0.2.10; }
        _argo_prepare_fixed_tunnel_from_state() { :; }
        svc_apply_tunnel() { :; }
        svc_exec() { return 1; }
        svc_exec_mut() { :; }
        svc_verify_health() { :; }
        argo_check_health() { :; }
        config_apply() { config_synthesize > "$CONFIG_FILE"; }
        download_cloudflared() { :; }
        fw_reconcile() { fw_desired_rules > "$_FW_PORTS_FILE"; }
        prompt() { printf -v "$2" '%s' "$choice"; }
        check_split() {
            local present="$1"
            if [ "$present" = yes ]; then
                jq -e 'any(.inbounds[]; .port == 28443)' "$CONFIG_FILE" >/dev/null || exit 1
                grep -qx '28443/tcp' "$_FW_PORTS_FILE" || exit 1
            else
                jq -e 'all(.inbounds[]; .port != 28443)' "$CONFIG_FILE" >/dev/null || exit 1
                if grep -qx '28443/tcp' "$_FW_PORTS_FILE"; then exit 1; fi
            fi
        }
        _commit
        check_split yes
        choice=1
        module_argo_update_protocol
        check_split no
        choice=2
        module_argo_update_protocol
        check_split yes
        module_argo_disable
        check_split no
        module_argo_enable
        check_split yes
        echo ARGO_LISTENER_TRANSITIONS_PASSED
    ''', timeout=60)
    assert 'ARGO_LISTENER_TRANSITIONS_PASSED' in output


def test_argo_xhttp_menu_and_runtime_rollback():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled=true | .argo.protocol="xhttp" | .reality.enabled=true'
        st_persist
        printf '%s' original > "${CONFIG_FILE}"
        _pause() { :; }
        prompt() { IFS= read -r "$2"; }
        _argo_xhttp_menu 0 <<< $'1\n3\n28443\n6\n0'
        st_get '.argo.xhttp' | jq -e '.server == {} and .client == {} and (has("split") | not)' >/dev/null
        port_mgr_in_use() { return 1; }
        _commit_inner() {
            [ "$(st_get '.argo.xhttp.split.port')" = 28443 ] || return 1
            printf '%s' changed > "${CONFIG_FILE}"
            st_persist || return 1
            printf '%s\n' 'simulated commit failure'
            return 1
        }
        if _argo_xhttp_set_profile 1 '{"split":{"port":28443}}'; then exit 1; fi
        [ "$(cat "${CONFIG_FILE}")" = original ]
        [ -z "$(st_get '.argo.xhttp')" ]
        jq -e '.argo.xhttp == null' "${STATE_FILE}" >/dev/null
        printf '%s\n' 'Argo XHTTP rollback verified'
    ''', timeout=35)
    assert_true('simulated commit failure' in out and 'Argo XHTTP rollback verified' in out, out)


def test_argo_xhttp_legacy_and_profile_exports_share_uri_authority():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        st_set '.argo.enabled = true | .argo.protocol = "xhttp" | .argo.auth_protocol = "vless" |
                .argo.domain = "fixture.invalid" | .cfip = "2001:db8::3" | del(.argo.xhttp)'
        plugin_refresh_runtime || exit 1
        legacy=$(_plg_argo_link) || exit 2
        explicit=$(_argo_xhttp_link normal) || exit 3
        [[ $legacy == "$explicit" && $legacy == *@\[2001:db8::3\]:* ]] || exit 4
        _argo_xhttp_export_json normal | jq -e '.settings.vnext[0].address == "2001:db8::3"' >/dev/null || exit 5
        st_set '.cfip = "[2001:db8::3]"'
        [[ $(_plg_argo_link) == "$legacy" ]] || exit 6
        _argo_xhttp_export_json normal | jq -e '.settings.vnext[0].address == "2001:db8::3"' >/dev/null || exit 7
    """)


def test_argo_xhttp_editor_and_selected_exports():
    import json
    from urllib.parse import parse_qs, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled=true | .argo.protocol="xhttp" | .argo.domain="tunnel.example.com" |
                .xpad.argo=true | .argo.xhttp.client=false |
                .reality.enabled=true | .reality.pbk="fixture-public" |
                .reality.pvk="fixture-private" | .reality.sni="example.com" | .reality.sid="abcd"'
        port_mgr_in_use() { return 1; }
        platform_get_realip() { printf '192.0.2.10\n'; }
        _pause() { :; }
        candidate='{"client":{"xmux":{"maxConcurrency":2,"maxConnections":3}}}'
        fixed='{"mode":"auto","server":{"xPaddingBytes":"128-768"},"client":{"xmux":{"maxConcurrency":2}},"split":{"port":28443,"download":{"xhttpSettings":{"extra":{"xmux":{"maxConnections":5}}}}}}'
        prompt() {
            if [ "$2" = _draft ] && [[ "$1" == '编辑单行 JSON'* ]]; then
                [[ "$#" -eq 3 && -z "$3" ]] || exit 1
                printf 'Advanced input starts empty\n'
            elif [ "$2" = _raw ]; then
                [[ "$#" -eq 3 && -z "$3" ]] || exit 1
            fi
            IFS= read -r "$2"
        }
        _argo_xhttp_menu 0 <<< $'7\n2\n900-100\n128-768\n3\n2\n0\n0'
        jq -e '.argo.xhttp | .server.xPaddingBytes == "128-768" and
            .server.xPaddingObfsMode == true and .client.xmux.maxConnections == 2' <<< "${_G_STATE}" >/dev/null
        _argo_xhttp_menu 0 <<< $'2\n'"$candidate"$'\n'"$fixed"$'\n7\n3\n3\n-\n4\n4\n7\nstream-up\n0\n4\n1\n0\n1\n1\n2\n1\n2\n2\n0\n0'
        jq -e '.argo.xhttp | .mode == "auto" and .client.xmux.maxConcurrency == 4 and
            .split.download.xhttpSettings.extra.xmux.maxConnections == 5' <<< "${_G_STATE}" >/dev/null
        _argo_xhttp_export_menu <<< $'2\n3\n0\n'
        st_set '.argo.xhttp.split.download.security = "tls" |
            .argo.xhttp.split.download.tlsSettings = {serverName:"down.example.com",alpn:["h2"]}'
        printf 'TLS_DOWN=%s\n' "$(_argo_xhttp_export_mihomo | jq -c .)"
        printf 'Argo editor state verified\n'
    ''', timeout=40)
    assert_true(out.count('Advanced input starts empty') == 2, out)
    for marker in ('server.xPaddingBytes', 'client.xmux.maxConnections', '当前 XHTTP JSON:',
                   'Padding 旧版设置', 'REALITY 上行 TCP 28443', 'Argo editor state verified'):
        assert_true(marker in out, f'Missing {marker}: {out}')
    links = [urlsplit(line) for line in out.splitlines() if line.startswith('vless://')]
    assert [link.fragment for link in links] == ['Argo-XHTTP', 'Argo-XHTTP-Split']
    normal_extra, split_extra = [json.loads(parse_qs(link.query)['extra'][0]) for link in links]
    assert 'downloadSettings' not in normal_extra
    decoder = json.JSONDecoder()
    outbound, _ = decoder.raw_decode(out[out.index('{\n  "protocol": "vless"'):])
    assert outbound['streamSettings']['xhttpSettings']['extra'] == split_extra
    expected_public_key = 'fixture-public'
    assert outbound['streamSettings']['realitySettings']['password'] == expected_public_key
    assert parse_qs(links[1].query)['pbk'] == [expected_public_key]
    assert links[1].hostname == '192.0.2.10' and links[1].port == 28443
    assert split_extra['downloadSettings']['security'] == 'tls'
    assert parse_qs(links[0].query)['mode'] == ['auto']
    assert parse_qs(links[1].query)['mode'] == ['stream-up']
    assert outbound['streamSettings']['xhttpSettings']['mode'] == 'stream-up'
    assert out.count('{\n  "protocol": "vless"') == 1
    assert 'support-x25519mlkem768' not in parse_qs(links[0].query)
    assert parse_qs(links[1].query)['support-x25519mlkem768'] == ['true']
    assert 'support-x25519mlkem768' not in json.dumps(outbound)
    provider, _ = decoder.raw_decode(out[out.index('{\n  "proxies": ['):])
    proxy, = provider['proxies']
    assert proxy['type'] == 'vless' and proxy['network'] == 'xhttp' and proxy['tls'] is True
    assert proxy['server'] == '192.0.2.10' and proxy['port'] == 28443
    assert proxy['servername'] == 'example.com' and proxy['client-fingerprint'] == 'chrome'
    assert proxy['reality-opts'] == {'public-key': expected_public_key, 'short-id': 'abcd',
                                     'support-x25519mlkem768': True}
    xhttp = proxy['xhttp-opts']
    assert xhttp['mode'] == 'stream-up' and xhttp['x-padding-bytes'] == '128-768'
    assert xhttp['reuse-settings']['max-concurrency'] == '4'
    down = xhttp['download-settings']
    assert down == {'server': 'cf.tencentapp.cn', 'port': 443, 'tls': True, 'path': '/argo',
                    'host': 'tunnel.example.com', 'servername': 'tunnel.example.com',
                    'client-fingerprint': 'chrome', 'reuse-settings': {'max-connections': '5'},
                    'reality-opts': {'public-key': ''}}
    tls_output = next(line[9:] for line in out.splitlines() if line.startswith('TLS_DOWN='))
    tls_down = json.loads(tls_output)['proxies'][0]['xhttp-opts']['download-settings']
    assert tls_down['tls'] is True and tls_down['servername'] == 'down.example.com' and tls_down['alpn'] == ['h2']
    assert tls_down['reality-opts'] == {'public-key': ''}
    assert 'fixture-private' not in out


def test_help_runs_before_privileged_setup():
    out = run_bash(r'''
        source ./xray_2go.sh
        check_root() { exit 11; }
        platform_preflight() { exit 12; }
        st_init() { exit 13; }
        plugin_refresh_runtime() { exit 14; }
        main --help
    ''')
    assert_true('xray2go --help' in out, out)


def test_argo_enable_rolls_back_on_start_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false' >/dev/null
        download_cloudflared() { return 0; }
        config_apply() { return 0; }
        svc_apply_tunnel() { return 0; }
        svc_reload_daemon() { return 0; }
        svc_exec_mut() { [ "$1" = "start" ] && return 1; return 0; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        module_argo_enable
        rc=$?
        printf 'module-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true("module-rc=0" not in cp.stdout, "Argo start failure must not return success")
    assert_true("enabled=false" in cp.stdout, "Argo state must roll back after start failure")


def test_argo_enable_health_failure_rolls_back():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false' >/dev/null
        download_cloudflared() { return 0; }
        config_apply() { return 0; }
        svc_apply_tunnel() { return 0; }
        svc_reload_daemon() { return 0; }
        svc_exec_mut() { return 0; }
        svc_verify_health() { printf 'health-called\\n'; return 1; }
        st_persist() { return 0; }
        fw_reconcile() { return 0; }
        module_argo_enable
        rc=$?
        printf 'module-rc=%s enabled=%s\\n' "$rc" "$(st_get '.argo.enabled')"
        exit 0
    """)
    assert_true(cp.returncode == 0, f"Argo health rollback probe process failed: {cp.stdout}")
    assert_true("health-called" in cp.stdout, "Argo enable must verify Tunnel health after start")
    assert_true("module-rc=1" in cp.stdout and "enabled=false" in cp.stdout, "health failure must roll back Argo enable")


def test_runtime_argo_enable_restores_cross_artifact_state_after_start_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
printf '#!/bin/sh\\n' > "${ARGO_BIN}"
chmod 700 "${ARGO_BIN}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=0
_SERVICE_ENABLED=0
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 0
}
svc_apply_tunnel() {
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    return 0
}
svc_reload_daemon() { return 0; }
fw_reconcile() { return 0; }
svc_exec_mut() {
    case "$1" in
        enable) _SERVICE_ENABLED=1; return 0 ;;
        disable) _SERVICE_ENABLED=0; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 1 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
    esac
    return 1
}
module_argo_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s config=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "config=old-config service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=0 enabled=0" in cp.stdout,
        f"failed Argo start must restore state, artifacts and service status: {cp.stdout}",
    )


def test_transaction_retains_snapshot_when_restore_fails():
    with XraySandbox() as sandbox:
        for interrupt in ('false', 'true'):
            cp = subprocess.run(
                ['bash', '-lc', r'''
                    source ./xray_2go.sh
                    mkdir -p "${WORK_DIR}"
                    printf 'original\n' > "${CONFIG_FILE}"
                    _transaction_restore_files() { return 1; }
                    apply_failure() {
                        printf 'invalid\n' > "${CONFIG_FILE}"
                        if [ "$interrupt" = true ]; then kill -TERM $$; fi
                        return 1
                    }
                    _transaction_run '写入测试' apply_failure
                '''],
                cwd=ROOT,
                env={**sandbox.environment(), 'interrupt': interrupt},
                text=True, capture_output=True, timeout=20, check=False,
            )
            snapshots = sorted((sandbox.root / 'etc/xray2go').glob('.txn_*'))
            assert cp.returncode == (130 if interrupt == 'true' else 1), cp.stderr
            assert len(snapshots) == (2 if interrupt == 'true' else 1), cp.stderr
            for snapshot in snapshots:
                assert snapshot.stat().st_mode & 0o077 == 0
                assert (snapshot / 'files/0').read_text() == 'original\n'
            assert any(str(path).removeprefix(str(sandbox.root)) in cp.stderr for path in snapshots), cp.stderr


def test_xray_manual_restart_holds_deployment_lock():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        mkdir -p "${WORK_DIR}"
        printf 'config\n' > "${CONFIG_FILE}"
        lock_held() {
            ! flock -n "${_LOCK_FILE}" true
        }
        svc_apply_xray() { lock_held; }
        svc_exec_mut() { [[ "$1" == restart ]] && lock_held; }
        svc_verify_health() { lock_held; }
        module_restart_action xray
        flock -n "${_LOCK_FILE}" true
    ''')


def test_transaction_interrupt_restores_files_and_state():
    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                "source ./xray_2go.sh\n"
                "mkdir -p \"${WORK_DIR}\"\n"
                "printf 'old-config\\n' > \"${CONFIG_FILE}\"\n"
                "_G_STATE=\"${_STATE_DEFAULT}\"\n"
                "_st_normalize_schema >/dev/null\n"
                "st_set '.argo.enabled = false' >/dev/null\n"
                "st_persist >/dev/null\n"
                "_interrupt_probe() {\n"
                "    printf 'new-config\\n' > \"${CONFIG_FILE}\"\n"
                "    st_set '.argo.enabled = true' >/dev/null\n"
                "    kill -INT $$\n"
                "}\n"
                "_transaction_run '中断测试' _interrupt_probe\n",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        config = (sandbox.root / "etc/xray2go/config.json").read_text(encoding="utf-8")
        state = (sandbox.root / "etc/xray2go/state.json").read_text(encoding="utf-8")
    assert_true(cp.returncode == 130, f"SIGINT must exit with 130: {cp.stdout}")
    assert_true(config.startswith("old-config") and config.endswith("\n"), f"SIGINT must restore config artifact: {config!r}")
    assert_true('"enabled":false' in state.replace(" ", ""), f"SIGINT must restore persisted state: {state}")


def test_concurrent_transactions_serialize_failure_and_commit():
    with XraySandbox() as sandbox:
        work_dir = sandbox.root / "etc/xray2go"
        work_dir.mkdir(parents=True, exist_ok=True)
        (work_dir / "config.json").write_text("old-config\\n", encoding="utf-8")
        command = (
            "source ./xray_2go.sh\n"
            "mkdir -p \"${WORK_DIR}\"\n"
            "_G_STATE=\"${_STATE_DEFAULT}\"\n"
            "_st_normalize_schema >/dev/null\n"
            "_probe() {\n"
            "    printf '%s-start\\n' \"${LABEL}\" >> \"${WORK_DIR}/timeline\"\n"
            "    printf '%s\\n' \"${LABEL}\" > \"${CONFIG_FILE}\"\n"
            "    sleep 0.4\n"
            "    printf '%s-end\\n' \"${LABEL}\" >> \"${WORK_DIR}/timeline\"\n"
            "    return \"${RESULT}\"\n"
            "}\n"
            "_transaction_run \"${LABEL}\" _probe\n"
        )
        env_a = sandbox.environment()
        env_a.update({"LABEL": "A", "RESULT": "1"})
        env_b = sandbox.environment()
        env_b.update({"LABEL": "B", "RESULT": "0"})
        proc_a = subprocess.Popen(
            ["bash", "-lc", command],
            cwd=ROOT,
            env=env_a,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        time.sleep(0.05)
        proc_b = subprocess.Popen(
            ["bash", "-lc", command],
            cwd=ROOT,
            env=env_b,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        out_a, _ = proc_a.communicate(timeout=20)
        out_b, _ = proc_b.communicate(timeout=20)
        timeline = (work_dir / "timeline").read_text(encoding="utf-8").splitlines()
        final_config = (work_dir / "config.json").read_text(encoding="utf-8")
    assert_true(proc_a.returncode == 1, f"failed transaction must return failure: {out_a}")
    assert_true(proc_b.returncode == 0, f"waiting transaction must commit successfully: {out_b}")
    assert_true(timeline in (["A-start", "A-end", "B-start", "B-end"], ["B-start", "B-end", "A-start", "A-end"]), f"transactions must not overlap: {timeline}")
    assert_true(final_config.startswith("B") and final_config.endswith("\n"), f"later successful transaction must own final artifact: {final_config!r}")


def test_runtime_argo_disable_restores_service_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        disable) _SERVICE_ENABLED=0; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
    esac
    return 1
}
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    return 1
}
fw_reconcile() { return 0; }
module_argo_disable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s config=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo disable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "config=old-config service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed Argo disable must restore state, artifacts and service status: {cp.stdout}",
    )


def test_runtime_argo_uninstall_restores_deleted_artifacts_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
printf 'old-argo' > "${ARGO_BIN}"
chmod 700 "${ARGO_BIN}"
st_init >/dev/null 2>&1
st_set '.argo.enabled = true | .argo.domain = "old.example.com"' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-yml' > "${WORK_DIR}/tunnel.yml"
printf 'old-json' > "${WORK_DIR}/tunnel.json"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() { [ "$1" = status ] && [ "${_SERVICE_ACTIVE}" = 1 ]; }
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        disable) _SERVICE_ENABLED=0; return 0 ;;
        stop) _SERVICE_ACTIVE=0; return 0 ;;
        enable) _SERVICE_ENABLED=1; return 0 ;;
        start) _SERVICE_ACTIVE=1; return 0 ;;
    esac
    return 1
}
is_systemd() { return 0; }
systemctl() { return 0; }
config_apply() { return 1; }
fw_reconcile() { return 0; }
module_argo_uninstall >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s state=%s argo=%s service=%s env=%s yml=%s json=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.argo.enabled')" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${ARGO_BIN}" 2>/dev/null || printf missing)" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service" 2>/dev/null || printf missing)" \\
    "$(cat "${_ARGO_ENV_FILE}" 2>/dev/null || printf missing)" \\
    "$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || printf missing)" \\
    "$(cat "${WORK_DIR}/tunnel.json" 2>/dev/null || printf missing)" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Argo uninstall rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "argo=old-argo service=old-service env=old-env yml=old-yml json=old-json fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed Argo uninstall must restore deleted artifacts and service status: {cp.stdout}",
    )


def test_argo_domain_update_rolls_back_on_apply_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true | .argo.domain = "old.example.com"' >/dev/null
        prompt() { printf -v "$2" '%s' 'new.example.com'; }
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        module_argo_update_domain
        rc=$?
        printf 'module-rc=%s domain=%s\\n' "$rc" "$(st_get '.argo.domain')"
        exit 0
    """)
    assert_true(cp.returncode == 0, "domain rollback probe should complete")
    assert_true("module-rc=0" not in cp.stdout, "domain update must fail when Argo apply fails")
    assert_true("domain=old.example.com" in cp.stdout, "Argo domain must roll back after apply failure")


def test_argo_domain_update_rolls_back_null_domain_type_on_apply_failure():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = true | .argo.domain = null' >/dev/null
        prompt() { printf -v "$2" '%s' 'new.example.com'; }
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        module_argo_update_domain
        rc=$?
        printf 'module-rc=%s domain_type=%s domain=%s\\n' "$rc" "$(printf '%s' "${_G_STATE}" | jq -r '.argo.domain | type')" "$(st_get '.argo.domain')"
        exit 0
    """)
    assert_true(cp.returncode == 0, "null-domain rollback probe should complete")
    assert_true("module-rc=0" not in cp.stdout, "domain update must fail when Argo apply fails")
    assert_true("domain_type=null" in cp.stdout, "Argo domain rollback must preserve JSON null type")


def test_freeflow_and_direct_h3_xhttp_workbench_profiles():
    import json
    from urllib.parse import parse_qs, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.ff.enabled=true | .ff.protocol="xhttp" | .ff.path="/ff-test" | .xpad.ff=true |
                .vlquic.enabled=true | .vlquic.domain="h3.example.com" |
                .vlquic.cert="/fixture/cert.pem" | .vlquic.key="/fixture/key.pem"'
        platform_get_realip() { printf '192.0.2.20'; }
        plugin_refresh_runtime
        clear() { :; }
        _pause() { :; }
        prompt() { IFS= read -r "$2"; }
        for m in ff vlquic; do
            printf '%s-legacy=%s\n' "$m" "$(plugin_collect_links "$m")"
        done
        draft='{"server":{"xPaddingBytes":"128-768"},"client":{"xmux":{"maxConnections":4}}}'
        unified_menu_freeflow install <<< $'x\n1\n3\n2\n'"$draft"$'\n3\n1\n3\n2\n0\n0'
        unified_menu_vlquic install <<< $'x\n1\n4\n2\n'"$draft"$'\n3\n1\n3\n2\n0\n0'
        for m in ff vlquic; do
            if "_${m}_xhttp_set_profile" 0 '{"client":{"xhttpModeH3":false}}'; then exit 1; fi
            printf '%s-in=%s\n' "$m" "$(plugin_call "$m" inbound | jq -ce .)"
            printf '%s-link=%s\n' "$m" "$(plugin_collect_links "$m")"
            printf '%s-out=%s\n' "$m" "$("_${m}_xhttp_export_json" | jq -ce .)"
            "_${m}_xhttp_set_profile" 0 null
            printf '%s-reset=%s\n' "$m" "$(plugin_collect_links "$m")"
        done
        [[ $(plugin_call vlquic ports) == */udp ]]
        st_set '.ff.protocol="ws"'
        [[ $(plugin_collect_links ff) == *'type=ws'* ]]
    ''', timeout=65)
    rows = dict(line.split('=',1) for line in out.splitlines() if re.match(r'^(ff|vlquic)-\w+=',line))
    for mod, mode, path in [('ff', 'packet-up', '/ff-test'), ('vlquic', 'stream-up', '/')]:
        link = parse_qs(urlsplit(rows[mod+'-link']).query)
        inbound = json.loads(rows[mod+'-in'])['streamSettings']
        outbound = json.loads(rows[mod+'-out'])['streamSettings']
        assert inbound['xhttpSettings'] == {'mode': mode, 'path': path, 'xPaddingBytes': '128-768'}
        assert outbound['xhttpSettings']['mode'] == link['mode'][0] == mode
        extra = json.loads(link['extra'][0])
        if mod == 'vlquic':
            assert extra.pop('xhttpModeH3') is True
            assert inbound['tlsSettings']['alpn'] == outbound['tlsSettings']['alpn'] == link['alpn'] == ['h3']
            assert 'certificateFile' not in rows[mod+'-out'] and 'keyFile' not in rows[mod+'-out']
        assert outbound['xhttpSettings']['extra'] == extra == {'xPaddingBytes': '128-768', 'xmux': {'maxConnections':4}}
        assert rows[mod+'-legacy'] == rows[mod+'-reset']
        assert out.splitlines().count(rows[mod+'-link']) >= 1


def test_reality_xhttp_workbench_profiles_and_legacy_transport():
    import json
    from urllib.parse import parse_qs, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.reality.enabled = true | .reality.network = "xhttp" | .reality.pvk = "fixture-server-key" |
                .reality.pbk = "fixture-public-key" | .reality.sid = "abcdef01" | .reality.sni = "example.com" |
                .xpad.reality = true | del(.reality.xhttp)'
        platform_get_realip() { printf '[2001:db8::1]'; }
        plugin_refresh_runtime
        printf 'LEGACY=%s\n' "$(_plg_reality_link)"
        clear() { :; }
        _pause() { :; }
        prompt() { IFS= read -r "$2"; }
        unified_menu_reality install <<< $'x\n1\n3\n2\n{"server":{"xPaddingBytes":"128-768","scMaxBufferedPosts":35},"client":{"xmux":{"maxConnections":4}}}\n5\n3\n6\n0\n3\n1\n3\n2\n0\n0'
        for bad in '{"split":{"port":28443}}' '{"client":{"xhttpModeH3":true}}' '{"server":false}'; do
            if _reality_xhttp_set_profile 0 "$bad"; then exit 1; fi
        done
        printf 'INBOUND=%s\n' "$(_plg_reality_inbound | jq -c .)"
        printf 'LINK=%s\n' "$(_plg_reality_link)"
        printf 'OUTBOUND=%s\n' "$(_reality_xhttp_export_json | jq -c .)"
        st_persist
        config_apply() { _plg_reality_inbound > "$CONFIG_FILE"; }
        fw_reconcile() { [[ $(st_get '.reality.xhttp.mode') != stream-up ]]; }
        _reality_xhttp_set_profile 1 '{"mode":"packet-up","server":{"xPaddingBytes":"128-768","scMaxBufferedPosts":35},"client":{"xmux":{"maxConnections":6}}}'
        jq -e '.streamSettings.xhttpSettings.mode == "packet-up"' "$CONFIG_FILE" >/dev/null
        if _reality_xhttp_set_profile 1 '{"mode":"stream-up"}'; then exit 1; fi
        jq -e '.reality.xhttp.mode == "packet-up"' "$STATE_FILE" >/dev/null
        jq -e '.streamSettings.xhttpSettings.mode == "packet-up"' "$CONFIG_FILE" >/dev/null
        [[ $(st_get '.reality.xhttp.mode') == packet-up ]]
        st_set '.reality.network = "tcp"'
        printf 'TCP=%s\n' "$(_plg_reality_link)"
        st_set '.reality.network = "xhttp"'
        [[ $(_plg_reality_link) == *'mode=packet-up'* ]]
        _reality_xhttp_set_profile 0 null
        printf 'RESET=%s\n' "$(_plg_reality_link)"
    ''', timeout=60)
    records = dict(line.split('=', 1) for line in out.splitlines() if re.match(r'^[A-Z]+=', line))
    legacy = parse_qs(urlsplit(records['LEGACY']).query)
    link = parse_qs(urlsplit(records['LINK']).query)
    inbound = json.loads(records['INBOUND'])['streamSettings']['xhttpSettings']
    outbound = json.loads(records['OUTBOUND'])
    stream = outbound['streamSettings']
    extra = json.loads(link['extra'][0])
    assert legacy['mode'] == ['stream-one'] and json.loads(legacy['extra'][0])['xPaddingObfsMode'] is True
    assert inbound == {'path': '/', 'mode': 'packet-up', 'xPaddingBytes': '128-768', 'scMaxBufferedPosts': 35}
    assert stream['xhttpSettings'] == {'path': '/', 'mode': 'packet-up', 'extra': extra}
    assert extra == {'xPaddingBytes': '128-768', 'xmux': {'maxConnections': 6}}
    assert link['pbk'] == ['fixture-public-key']
    assert link['support-x25519mlkem768'] == ['true']
    assert link['fp'] == ['chrome']
    assert stream['realitySettings']['password'] == link['pbk'][0]
    assert 'support-x25519mlkem768' not in stream['realitySettings']
    assert outbound['settings']['vnext'][0]['address'] == '2001:db8::1'
    assert 'fixture-server-key' not in records['OUTBOUND'] + records['LINK']
    tcp = parse_qs(urlsplit(records['TCP']).query)
    assert tcp['flow'] == ['xtls-rprx-vision'] and tcp['type'] == ['tcp']
    assert tcp['support-x25519mlkem768'] == ['true'] and tcp['fp'] == ['chrome']
    assert records['RESET'] == records['LEGACY']
    assert records['LINK'] in out and 'Reality / XHTTP' in out


def test_cforigin_xhttp_menu_profiles_and_links():
    import json
    from urllib.parse import parse_qs, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.cforigin.enabled=true | .cforigin.origin_tls=false | .cforigin.protocol="xhttp" |
                .cforigin.domain="origin.example.com" | .cforigin.edge_port=8443 | .cforigin.path="/origin-test" |
                del(.cforigin.xhttp)'
        plugin_refresh_runtime
        printf 'LEGACY=%s\n' "$(_plg_cforigin_link)"
        check_xray() { return 1; }
        clear() { :; }
        _pause() { :; }
        prompt() { IFS= read -r "$2"; }
        unified_menu_cforigin install <<< $'x\n1\n3\n2\n{"server":{"xPaddingBytes":"128-768","scMaxBufferedPosts":35},"client":{"xmux":{"maxConnections":4}}}\n0\n0'
        for bad in '{"split":{"port":28443}}' '{"client":{"xmux":{"maxConnections":2,"maxConcurrency":3}}}' '{"client":{"xhttpModeH3":true}}'; do
            if _cforigin_xhttp_set_profile 0 "$bad"; then exit 1; fi
        done
        printf 'INBOUND=%s\n' "$(_plg_cforigin_inbound | jq -c .)"
        printf 'NORMAL=%s\n' "$(_plg_cforigin_link)"
        st_set '.cforigin.edge_h3=true'
        rejected='{"client":{"xhttpModeH3":true}}'
        corrected='{"server":{"xPaddingBytes":"128-768","scMaxBufferedPosts":35},"client":{"xmux":{"maxConnections":3}}}'
        prompt() {
            if [ "$2" = _draft ] && [[ "$1" == '编辑单行 JSON'* ]]; then
                [[ "$#" -eq 3 && -z "$3" ]] || exit 1
            fi
            IFS= read -r "$2"
        }
        _cforigin_xhttp_menu 0 <<< $'2\n'"$rejected"$'\n'"$corrected"$'\n5\n3\n4\n0\n3\n1\n3\n2\n0'
        printf 'H3=%s\n' "$(_plg_cforigin_link)"
        printf 'OUTBOUND=%s\n' "$(_cforigin_xhttp_export_json | jq -c .)"
        st_set '.cforigin.protocol="ws"'
        printf 'WS=%s\n' "$(_plg_cforigin_link)"
        st_set '.cforigin.protocol="xhttp"'
        _cforigin_xhttp_set_profile 0 null
        printf 'DEFAULT=%s\n' "$(_plg_cforigin_link)"
        printf 'CF Origin generated outputs verified\n'
    ''', timeout=35)
    assert_true('CF Origin generated outputs verified' in out, out)
    assert_true('当前 XHTTP JSON:' in out and 'client.xhttpModeH3' in out, out)
    exported_link = next(line for line in out.splitlines() if line.startswith('vless://'))
    assert_true(f'H3={exported_link}' in out, out)
    json_start = '{\n  "protocol": "vless"'
    assert_true(out.count(json_start) == 1, out)
    exported_json, _ = json.JSONDecoder().raw_decode(out[out.index(json_start):])
    assert_true('XHTTP 参数与节点导出' in out, out)
    values = dict(re.findall(r'^(LEGACY|INBOUND|NORMAL|H3|OUTBOUND|WS|DEFAULT)=(.*)$', out, re.MULTILINE))
    assert exported_json == json.loads(values['OUTBOUND'])
    legacy = parse_qs(urlsplit(values['LEGACY']).query)
    inbound = json.loads(values['INBOUND'])
    normal_url = urlsplit(values['NORMAL'])
    normal = parse_qs(normal_url.query)
    h3_url = urlsplit(values['H3'])
    h3 = parse_qs(h3_url.query)
    outbound = json.loads(values['OUTBOUND'])
    ws = parse_qs(urlsplit(values['WS']).query)
    default = parse_qs(urlsplit(values['DEFAULT']).query)
    expected_extra = {'xPaddingBytes': '128-768', 'xmux': {'maxConnections': 4}}
    assert_true(legacy['mode'] == ['stream-one'] and 'extra' not in legacy, legacy)
    assert_true(inbound['streamSettings']['xhttpSettings'] == {
        'path': '/origin-test', 'mode': 'packet-up',
        'extra': {'xPaddingBytes': '128-768', 'scMaxBufferedPosts': 35},
    }, inbound)
    assert_true(normal_url.hostname == 'origin.example.com' and normal_url.port == 8443, normal_url)
    assert_true(normal['mode'] == ['packet-up'] and json.loads(normal['extra'][0]) == expected_extra, normal)
    h3_extra = {**expected_extra, 'xhttpModeH3': True}
    assert_true(len(h3['extra']) == 1 and json.loads(h3['extra'][0]) == h3_extra, h3)
    assert_true(h3['alpn'] == ['h3'] and h3['xhttpModeH3'] == ['true'] and h3_url.fragment.endswith('Experimental'), h3_url)
    stream = outbound['streamSettings']
    server = outbound['settings']['vnext'][0]
    assert_true((server['address'], server['port']) == ('origin.example.com', 8443), server)
    assert_true(stream['tlsSettings']['alpn'] == ['h3'] and stream['tlsSettings']['serverName'] == 'origin.example.com', stream)
    assert_true(stream['xhttpSettings'] == {
        'host': 'origin.example.com', 'path': '/origin-test', 'mode': 'packet-up', 'extra': expected_extra,
    }, stream)
    assert_true(ws['type'] == ['ws'] and 'mode' not in ws and 'extra' not in ws, ws)
    assert_true(default['mode'] == ['stream-one'] and json.loads(default['extra'][0]) == {'xhttpModeH3': True}, default)


def test_cforigin_xhttp_runtime_profile_rolls_back():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.cforigin.enabled=true | .cforigin.protocol="xhttp"'
        _commit_inner() { st_persist; }
        _cforigin_xhttp_set_profile 1 '{"mode":"stream-up","server":{"xPaddingBytes":"100-300"}}'
        printf '%s' original > "${CONFIG_FILE}"
        _commit_inner() {
            [ "$(st_get '.cforigin.xhttp.mode')" = packet-up ] || return 1
            printf '%s' modified > "${CONFIG_FILE}"
            st_persist || return 1
            printf '%s\n' 'simulated CF Origin commit failure'
            return 1
        }
        if _cforigin_xhttp_set_profile 1 '{"mode":"packet-up"}'; then exit 1; fi
        [ "$(cat "${CONFIG_FILE}")" = original ]
        [ "$(st_get '.cforigin.xhttp.mode')" = stream-up ]
        jq -e '.cforigin.xhttp.mode == "stream-up"' "${STATE_FILE}" >/dev/null
        printf '%s\n' 'CF Origin XHTTP rollback verified'
    ''', timeout=30)
    assert_true('simulated CF Origin commit failure' in out and 'CF Origin XHTTP rollback verified' in out, out)


def test_cforigin_plain_http_does_not_require_certificates():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null
        st_set '.argo.enabled = false | .cforigin.enabled = true | .cforigin.domain = "origin.example.com" | .cforigin.origin_tls = false | .cforigin.cert = "" | .cforigin.key = ""' >/dev/null
        plugin_refresh_runtime || exit 1
        install_plan_validate
    """)
    assert_true(cp.returncode == 0, "plain HTTP CF Origin should validate without certificate files")


def test_trojan_argo_capability_is_owned_by_main_script():
    assert_true('"auth_protocol": "vless"' in TEXT, "Argo must have an explicit authentication protocol state")
    assert_true('auth_protocol' in TEXT and 'trojan' in TEXT, "main script must contain the Trojan Argo capability")
    assert_true('protocol:"trojan"' in TEXT, "main script must render a Trojan inbound")
    assert_true('trojan://' in TEXT, "main script must render a Trojan share link")
    assert_true('val_trojan_password' in TEXT, "Trojan password must have a dedicated validator")


def test_legacy_trojan_script_is_removed_after_migration():
    assert_true(not (ROOT / "xray_2go_Trojan_Socks5.sh").exists(), "legacy standalone Trojan script must not remain after migration")


def test_state_normalizes_missing_trojan_password_field():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws"}}'
        _st_normalize_schema >/dev/null
        printf '%s' "${_G_STATE}" | jq -e '(.argo | has("trojan_password")) and .argo.trojan_password == ""' >/dev/null
    """)
    assert_true(cp.returncode == 0, "schema normalization must add a missing Trojan password field")


def test_state_self_heals_illegal_trojan_transport_combination():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"xhttp","auth_protocol":"trojan","trojan_password":""}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.auth_protocol == "vless"' >/dev/null
    """)
    assert_true(cp.returncode == 0, "normalization must heal Trojan with non-WS transport back to VLESS")


def test_illegal_trojan_transport_state_does_not_lock_config_synthesis():
    cp = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"xhttp","auth_protocol":"trojan","trojan_password":""}}'
        _st_normalize_schema >/dev/null 2>&1
        plugin_install_builtins >/dev/null 2>&1
        plugin_load_all >/dev/null 2>&1
        config_synthesize >/dev/null 2>&1
    """)
    assert_true(cp.returncode == 0, "healed state must not leave config synthesis fail-closed")


def test_argo_draft_and_runtime_transport_edits_share_field_rules():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled = true | .argo.protocol = "xhttp" | .argo.auth_protocol = "vless"'
        st_persist
        changes=0
        argo_apply_fixed_tunnel_from_state() { changes=$((changes+1)); }
        argo_check_health() { :; }
        config_print_nodes() { :; }
        prompt() { [[ "$input" != eof ]] && printf -v "$2" '%s' "$input"; }
        for action in install_plan_argo_update_protocol module_argo_update_protocol; do
            input=''
            "$action"
            [[ $(st_get '.argo.protocol') == xhttp && "$changes" -eq 0 ]]
            input=unexpected
            if "$action"; then exit 1; fi
            input=eof
            if "$action"; then exit 1; fi
            [[ $(st_get '.argo.protocol') == xhttp && "$changes" -eq 0 ]]
        done
        input=1
        install_plan_argo_update_protocol
        [[ $(st_get '.argo.protocol') == ws && "$changes" -eq 0 ]]
        st_set '.argo.protocol = "xhttp"'
        module_argo_update_protocol
        [[ $(st_get '.argo.protocol') == ws && "$changes" -eq 1 ]]
    ''', timeout=45)


def test_transport_switch_is_guarded_while_trojan_auth_is_active():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.trojan_password = "fixture"'
        st_persist
        argo_apply_fixed_tunnel_from_state() { exit 2; }
        prompt() { printf -v "$2" '%s' 2; }
        for action in install_plan_argo_update_protocol module_argo_update_protocol; do
            if "$action"; then exit 1; fi
            [[ $(st_get '.argo.protocol') == ws ]]
        done
    ''')


def test_runtime_argo_updates_roll_back_in_memory_state_on_apply_failure():
    # Behavioural probe: a failing fixed-tunnel apply must leave in-memory state untouched.
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "vless" | .argo.trojan_password = ""' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        prompt() { printf -v "$2" '%s' '2'; }
        module_argo_update_protocol >/dev/null 2>&1 && echo "proto_unexpected_ok"
        printf 'proto=%s\n' "$(st_get '.argo.protocol')"
        st_set '.argo.protocol = "ws"' >/dev/null
        module_argo_update_auth_protocol >/dev/null 2>&1 && echo "auth_unexpected_ok"
        printf 'auth=%s pw_empty=%s\n' \
            "$(st_get '.argo.auth_protocol')" \
            "$( [ -z "$(st_get '.argo.trojan_password')" ] && printf yes || printf no )"
    """)
    assert_true("proto_unexpected_ok" not in out, f"transport update must fail when tunnel apply fails: {out}")
    assert_true("proto=ws" in out, f"module_argo_update_protocol must roll back .argo.protocol on apply failure: {out}")
    assert_true("auth_unexpected_ok" not in out, f"auth update must fail when tunnel apply fails: {out}")
    assert_true("auth=vless" in out, f"module_argo_update_auth_protocol must roll back .argo.auth_protocol on apply failure: {out}")
    assert_true("pw_empty=yes" in out, f"auth rollback must also revert the seeded Trojan password: {out}")


def test_argo_disable_and_uninstall_reset_authentication_state():
    for fn in ["module_argo_uninstall", "install_plan_argo_toggle"]:
        owner = "module_argo_uninstall_inner" if fn == "module_argo_uninstall" else fn
        m = re.search(rf"{owner}\(\) \{{(?P<body>.*?)\n\}}", TEXT, re.S)
        assert_true(m, f"{owner} function missing")
        body = m.group("body")
        assert_true('.argo.auth_protocol = "vless"' in body, f"{owner} must reset Argo auth protocol")
        assert_true('.argo.protocol = "ws"' in body, f"{owner} must reset Argo transport protocol")


def test_trojan_password_generator_is_random_and_validator_safe():
    cp = run_bash_result("""
        source ./xray_2go.sh
        a=$(crypto_gen_trojan_password) || exit 90
        b=$(crypto_gen_trojan_password) || exit 91
        val_trojan_password "${a}" >/dev/null 2>&1 || exit 92
        val_trojan_password "${b}" >/dev/null 2>&1 || exit 93
        [ "${a}" != "${b}" ] || exit 94
    """)
    assert_true(
        cp.returncode == 0,
        f"crypto_gen_trojan_password must emit distinct validator-safe passwords (rc={cp.returncode}): {cp.stdout}",
    )


def test_state_drops_uri_unsafe_trojan_password_and_keeps_valid_one():
    bad = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws","auth_protocol":"trojan","trojan_password":"bad#pass?x@y"}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.trojan_password == ""' >/dev/null
    """)
    assert_true(
        bad.returncode == 0,
        f"normalization must drop a URI-unsafe stored Trojan password (rc={bad.returncode}): {bad.stdout}",
    )
    good = run_bash_result("""
        source ./xray_2go.sh
        _G_STATE='{"uuid":"56b6d850-1e42-48ef-8229-94f5d8292e54","argo":{"enabled":true,"protocol":"ws","auth_protocol":"trojan","trojan_password":"Good.pass_x~y-z"}}'
        _st_normalize_schema >/dev/null 2>&1
        printf '%s' "${_G_STATE}" | jq -e '.argo.trojan_password == "Good.pass_x~y-z"' >/dev/null
    """)
    assert_true(
        good.returncode == 0,
        f"normalization must keep a validator-safe stored Trojan password (rc={good.returncode}): {good.stdout}",
    )


TROJAN_STATE_SEED = (
    "_G_STATE='{\"uuid\":\"56b6d850-1e42-48ef-8229-94f5d8292e54\","
    "\"argo\":{\"enabled\":true,\"protocol\":\"ws\",\"auth_protocol\":\"trojan\",\"trojan_password\":\"\"}}'"
)


def test_install_plan_trojan_password_entry_generates_and_persists_password():
    out = run_bash("""
        source ./xray_2go.sh
        %s
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%%s' ''; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        _pw=$(st_get '.argo.trojan_password')
        printf 'len=%%s uuid_match=%%s valid=%%s\n' \
            "${#_pw}" \
            "$( [ "${_pw}" = "$(st_get '.uuid')" ] && printf yes || printf no )" \
            "$( val_trojan_password "${_pw}" >/dev/null 2>&1 && printf yes || printf no )"
    """ % TROJAN_STATE_SEED)
    assert_true("rc=fail" not in out, f"empty input must auto-generate a Trojan password: {out}")
    assert_true("valid=yes" in out, f"generated Trojan password must pass the validator: {out}")
    assert_true("uuid_match=no" in out, f"generated Trojan password must be independent from the UUID: {out}")


def test_install_plan_trojan_password_entry_requires_trojan_auth():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F install_plan_argo_update_trojan_password >/dev/null || exit 79
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%s' 'ValidPass_123'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "" ] || exit 81
    """)
    assert_true(
        cp.returncode == 0,
        f"Trojan password entry must refuse while Argo auth is VLESS (rc={cp.returncode}): {cp.stdout}",
    )


def test_install_plan_trojan_password_entry_rejects_uri_unsafe_input():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F install_plan_argo_update_trojan_password >/dev/null || exit 79
        %s
        _st_normalize_schema >/dev/null 2>&1
        st_set '.argo.trojan_password = $p' --arg p 'KeepMe_12345' >/dev/null
        prompt_secret() { printf -v "$2" '%%s' 'bad#pass?x@y'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "KeepMe_12345" ] || exit 81
    """ % TROJAN_STATE_SEED)
    assert_true(
        cp.returncode == 0,
        f"URI-unsafe input must be rejected without clobbering the stored password (rc={cp.returncode}): {cp.stdout}",
    )


def test_install_plan_trojan_password_entry_accepts_explicit_value():
    cp = run_bash_result("""
        source ./xray_2go.sh
        %s
        _st_normalize_schema >/dev/null 2>&1
        prompt_secret() { printf -v "$2" '%%s' 'Explicit.pass_9~x-y'; }
        install_plan_argo_update_trojan_password >/dev/null 2>&1 || exit 80
        [ "$(st_get '.argo.trojan_password')" = "Explicit.pass_9~x-y" ] || exit 81
    """ % TROJAN_STATE_SEED)
    assert_true(
        cp.returncode == 0,
        f"explicit validator-safe password must be persisted (rc={cp.returncode}): {cp.stdout}",
    )


def test_switching_argo_auth_to_trojan_seeds_independent_password():
    out = run_bash("""
        source ./xray_2go.sh
        _G_STATE="${_STATE_DEFAULT}"
        _st_normalize_schema >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws"' >/dev/null
        prompt() { printf -v "$2" '%s' '2'; }
        install_plan_argo_update_auth_protocol >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        _pw=$(st_get '.argo.trojan_password')
        printf 'auth=%s empty=%s uuid_match=%s valid=%s\n' \
            "$(st_get '.argo.auth_protocol')" \
            "$( [ -z "${_pw}" ] && printf yes || printf no )" \
            "$( [ "${_pw}" = "$(st_get '.uuid')" ] && printf yes || printf no )" \
            "$( val_trojan_password "${_pw}" >/dev/null 2>&1 && printf yes || printf no )"
    """)
    assert_true("rc=fail" not in out, f"switching Argo auth to Trojan must succeed: {out}")
    assert_true("auth=trojan" in out, f"Argo auth must become Trojan: {out}")
    assert_true("empty=no" in out and "valid=yes" in out, f"switching to Trojan must seed a stored password: {out}")
    assert_true("uuid_match=no" in out, f"seeded Trojan password must not reuse the UUID: {out}")


def test_trojan_password_entry_is_wired_into_menu_and_uses_secret_prompt():
    m = re.search(r"install_plan_argo_update_trojan_password\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(m, "install_plan_argo_update_trojan_password function missing")
    body = m.group("body")
    assert_true("prompt_secret" in body, "Trojan password entry must read the secret without echoing it")
    assert_true('prompt "Trojan' not in TEXT, "Trojan password must never be read with the echoing prompt helper")
    assert_true("crypto_gen_trojan_password" in body, "Trojan password entry must support auto-generation")
    assert_true("val_trojan_password" in body, "Trojan password entry must validate before writing state")
    menu = re.search(r"unified_menu_argo\(\) \{(?P<body>.*?)\n\}", TEXT, re.S)
    assert_true(menu, "unified_menu_argo function missing")
    menu_body = menu.group("body")
    assert_true("Trojan 密码" in menu_body, "Argo workbench must expose a Trojan password action")
    assert_true(
        "install_plan_argo_update_trojan_password" in menu_body,
        "Argo workbench must route the Trojan password action to the install-plan entry",
    )
    assert_true(
        "update_trojan_password" in menu_body,
        "Argo workbench must route the Trojan password action to the runtime module action",
    )


def test_runtime_trojan_password_update_is_dispatchable_and_persists():
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.trojan_password = ""' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 0; }
        config_print_nodes() { return 0; }
        prompt_secret() { printf -v "$2" '%s' 'Runtime.pass_1~x-y'; }
        module_dispatch argo update_trojan_password >/dev/null 2>&1 || { echo "rc=fail"; exit 0; }
        printf 'pw=%s\n' "$(st_get '.argo.trojan_password')"
    """)
    assert_true("rc=fail" not in out, f"runtime dispatch must support argo:update_trojan_password: {out}")
    assert_true("pw=Runtime.pass_1~x-y" in out, f"runtime Trojan password update must persist the new value: {out}")


def test_runtime_trojan_password_update_rolls_back_on_apply_failure():
    out = run_bash("""
        source ./xray_2go.sh
        declare -F module_argo_update_trojan_password >/dev/null || { echo "rc=missing"; exit 0; }
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.trojan_password = $p' --arg p 'Original.pass_1' >/dev/null
        argo_apply_fixed_tunnel_from_state() { return 1; }
        config_print_nodes() { return 0; }
        prompt_secret() { printf -v "$2" '%s' 'Replacement.pass_2'; }
        module_dispatch argo update_trojan_password >/dev/null 2>&1 && echo "rc=unexpected-ok"
        printf 'pw=%s\n' "$(st_get '.argo.trojan_password')"
    """)
    assert_true("rc=missing" not in out, f"module_argo_update_trojan_password must exist: {out}")
    assert_true("rc=unexpected-ok" not in out, f"runtime Trojan password update must fail when tunnel apply fails: {out}")
    assert_true(
        "pw=Original.pass_1" in out,
        f"runtime Trojan password update must roll back in-memory state on apply failure: {out}",
    )


def test_runtime_trojan_password_update_requires_enabled_argo():
    cp = run_bash_result("""
        source ./xray_2go.sh
        declare -F module_argo_update_trojan_password >/dev/null || exit 79
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = false | .argo.auth_protocol = "trojan"' >/dev/null
        prompt_secret() { printf -v "$2" '%s' 'Should.not_apply1'; }
        module_argo_update_trojan_password >/dev/null 2>&1 && exit 80
        [ "$(st_get '.argo.trojan_password')" = "" ] || exit 81
    """)
    assert_true(
        cp.returncode == 0,
        f"runtime Trojan password update must refuse while Argo is disabled (rc={cp.returncode}): {cp.stdout}",
    )


def test_stored_trojan_password_is_used_by_inbound_and_share_link():
    out = run_bash("""
        source ./xray_2go.sh
        st_init >/dev/null 2>&1
        st_set '.argo.enabled = true | .argo.protocol = "ws" | .argo.auth_protocol = "trojan" | .argo.domain = "t.example.com" | .argo.trojan_password = $p' --arg p 'Link.pass_9~x-y' >/dev/null
        plugin_install_builtins >/dev/null 2>&1
        plugin_load_all >/dev/null 2>&1
        _plg_argo_inbound | jq -r '.settings.clients[0].password' | sed 's/^/inbound=/'
        printf 'link=%s\n' "$(_plg_argo_link)"
    """)
    assert_true("inbound=Link.pass_9~x-y" in out, f"stored Trojan password must drive the inbound: {out}")
    assert_true("link=trojan://Link.pass_9~x-y@" in out, f"stored Trojan password must drive the share link: {out}")


def test_runtime_restart_status_actions_have_single_canonical_owner():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh

declare -F module_restart_action >/dev/null || { echo 'missing_restart_owner'; exit 79; }
declare -F module_status_action >/dev/null || { echo 'missing_status_owner'; exit 80; }

module_restart_action() { printf 'restart=%s\\n' "$1"; }
module_status_action() { printf 'status=%s\\n' "$1"; }

module_dispatch ff restart
module_dispatch argo restart
check_xray
check_argo
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"restart/status canonical-owner RED/GREEN probe failed: {cp.stdout}")
    assert_true("restart=xray" in cp.stdout, f"non-Argo restart must route to the canonical xray owner: {cp.stdout}")
    assert_true("restart=argo" in cp.stdout, f"Argo restart must route to the canonical Argo owner: {cp.stdout}")
    assert_true("status=xray" in cp.stdout, f"xray status must route to the canonical status owner: {cp.stdout}")
    assert_true("status=argo" in cp.stdout, f"Argo status must route to the canonical status owner: {cp.stdout}")

    for function_name, target in (
        ("module_xray_restart", "xray"),
        ("module_argo_restart", "argo"),
        ("check_xray", "xray"),
        ("check_argo", "argo"),
    ):
        match = re.search(
            rf"^{re.escape(function_name)}\(\) \{{(?P<body>.*?)^\}}",
            TEXT,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"compatibility wrapper missing: {function_name}")
        body = match.group("body")
        owner = "module_restart_action" if function_name.startswith("module_") else "module_status_action"
        assert_true(
            f"{owner} {target}" in body,
            f"{function_name} must delegate to {owner} {target}, not duplicate action logic",
        )


def test_runtime_restart_status_canonical_owner_preserves_failure_and_status_contract():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1

check_xray_install() { return 0; }
svc_restart_xray() { return 1; }
module_restart_action xray >/dev/null 2>&1
printf 'xray_restart_rc=%s\\n' "$?"

svc_exec_mut() { return 0; }
svc_verify_health() { return 1; }
module_restart_action argo >/dev/null 2>&1
printf 'argo_restart_rc=%s\\n' "$?"

svc_exec() { return 0; }
_xray_status=$(module_status_action xray); _xray_status_rc=$?
printf 'xray_status=%s xray_status_rc=%s\\n' "${_xray_status}" "${_xray_status_rc}"

st_set '.argo.enabled = true' >/dev/null
mkdir -p "$(dirname "${ARGO_BIN}")"
touch "${ARGO_BIN}"
_argo_status=$(module_status_action argo); _argo_status_rc=$?
printf 'argo_status=%s argo_status_rc=%s\\n' "${_argo_status}" "${_argo_status_rc}"

svc_exec() { return 1; }
_stopped=$(module_status_action xray); _stopped_rc=$?
printf 'stopped_status=%s stopped_status_rc=%s\\n' "${_stopped}" "${_stopped_rc}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"canonical restart/status behavior probe failed: {cp.stdout}")
    assert_true("xray_restart_rc=1" in cp.stdout, f"xray restart failure must propagate: {cp.stdout}")
    assert_true("argo_restart_rc=1" in cp.stdout, f"Argo health failure must propagate: {cp.stdout}")
    assert_true("xray_status=running xray_status_rc=0" in cp.stdout, f"xray running status contract changed: {cp.stdout}")
    assert_true("argo_status=running argo_status_rc=0" in cp.stdout, f"Argo running status contract changed: {cp.stdout}")
    assert_true("stopped_status=stopped stopped_status_rc=1" in cp.stdout, f"stopped status contract changed: {cp.stdout}")


def test_runtime_socks_disable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_disable_commit() { return 1; }
module_socks_action disable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.socks.enabled')
_disk=$(jq -r '.socks.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"socks disable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed SOCKS disable must restore committed state: {cp.stdout}",
    )


def test_runtime_socks_enable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_socks_action enable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.socks.enabled')
_disk=$(jq -r '.socks.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"socks enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed SOCKS enable must restore committed state: {cp.stdout}",
    )


def test_runtime_vltcp_enable_failure_restores_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.vltcp.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_vltcp_enable >/dev/null 2>&1
_rc=$?
_mem=$(st_get '.vltcp.enabled')
_disk=$(jq -r '.vltcp.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"vltcp enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"failed VLESS-TCP enable must restore committed state: {cp.stdout}",
    )


def test_shared_enable_helper_restores_state_on_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.vltcp.enabled = true' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
_module_enable_with_state '.vltcp.enabled = false' 'VLESS-TCP'
_rc=$?
_mem=$(st_get '.vltcp.enabled')
_disk=$(jq -r '.vltcp.enabled' "${STATE_FILE}")
printf 'rc=%s memory=%s disk=%s\\n' "${_rc}" "${_mem}" "${_disk}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"shared enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true disk=true" in cp.stdout,
        f"shared enable helper must restore prior state: {cp.stdout}",
    )


def test_runtime_ff_enable_failure_restores_complete_previous_state():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.ff.enabled = true | .ff.protocol = "tcphttp" | .ff.host = "old.example"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_ff_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s disk=%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(st_get '.ff.enabled')" \\
    "$(st_get '.ff.protocol')" \\
    "$(st_get '.ff.host')" \\
    "$(jq -r '.ff.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.ff.protocol' "${STATE_FILE}")" \\
    "$(jq -r '.ff.host' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"FreeFlow enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true/tcphttp/old.example disk=true/tcphttp/old.example" in cp.stdout,
        f"failed FreeFlow enable must restore complete prior state: {cp.stdout}",
    )


def test_runtime_reality_enable_failure_restores_generated_material():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "$(dirname "${XRAY_BIN}")"
printf '%s\\n' \\
    '#!/bin/sh' \\
    'case "${1:-}" in' \\
    '  x25519) printf "%s\\n%s\\n" "Private key: NEWPRIVATEKEY_1234567890" "Public key: NEWPUBLICKEY_1234567890" ;;' \\
    '  *) exit 1 ;;' \\
    'esac' > "${XRAY_BIN}"
chmod 700 "${XRAY_BIN}"
st_init >/dev/null 2>&1
st_set '.reality.enabled = false | .reality.pvk = null | .reality.pbk = null | .reality.sid = "oldsid"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_reality_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s/%s disk=%s/%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.enabled')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.pvk')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.pbk')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.reality.sid')" \\
    "$(jq -r '.reality.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.reality.pvk' "${STATE_FILE}")" \\
    "$(jq -r '.reality.pbk' "${STATE_FILE}")" \\
    "$(jq -r '.reality.sid' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"Reality enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false/null/null/oldsid disk=false/null/null/oldsid" in cp.stdout,
        f"failed Reality enable must restore generated material and prior state: {cp.stdout}",
    )


def test_runtime_transaction_restores_cross_artifact_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"

svc_exec() { return 1; }
svc_exec_mut() { return 0; }
_fw_restore_managed_snapshot() { return 0; }
_module_enable_commit() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf '{"socks":{"enabled":true}}' > "${STATE_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
module_socks_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"transaction rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false config=old-config state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_disable_transaction_restores_cross_artifact_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_fw_remove_rule() { return 0; }
_fw_open_port_backend() { _fw_mark_rule "$@"; }
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() {
    case "$1" in
        status) [ "${_SERVICE_ACTIVE}" = 1 ] ;;
        *) return 1 ;;
    esac
}
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        start) _SERVICE_ACTIVE=1 ;;
        stop) _SERVICE_ACTIVE=0 ;;
        enable) _SERVICE_ENABLED=1 ;;
        disable) _SERVICE_ENABLED=0 ;;
        *) return 1 ;;
    esac
}
_fw_restore_managed_snapshot() { return 0; }
_module_disable_commit() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf '{"socks":{"enabled":false}}' > "${STATE_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    _SERVICE_ACTIVE=0
    _SERVICE_ENABLED=0
    return 1
}
module_socks_action disable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s active=%s enabled=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")" \\
    "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"disable transaction rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true config=old-config state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080 active=1 enabled=1" in cp.stdout,
        f"failed disable commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_commit_restores_cross_artifact_state_after_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = true' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_fw_remove_rule() { return 0; }
_fw_open_port_backend() { _fw_mark_rule "$@"; }
_commit_inner() {
    st_set '.socks.enabled = false' >/dev/null
    st_persist >/dev/null 2>&1
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
_commit >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.socks.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"ordinary commit rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=true config=old-config state={" in cp.stdout
        and '"enabled":true' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed ordinary commit must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_transaction_restores_service_enabled_state_after_commit_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.socks.enabled = false' >/dev/null
st_persist >/dev/null 2>&1
_SERVICE_ACTIVE=1
_SERVICE_ENABLED=1
svc_exec() {
    case "$1" in
        status) [ "${_SERVICE_ACTIVE}" = 1 ] ;;
        *) return 1 ;;
    esac
}
svc_is_enabled() { [ "${_SERVICE_ENABLED}" = 1 ]; }
svc_exec_mut() {
    case "$1" in
        start) _SERVICE_ACTIVE=1 ;;
        stop) _SERVICE_ACTIVE=0 ;;
        enable) _SERVICE_ENABLED=1 ;;
        disable) _SERVICE_ENABLED=0 ;;
        *) return 1 ;;
    esac
}
_fw_restore_managed_snapshot() { return 0; }
_module_enable_commit() {
    _SERVICE_ACTIVE=0
    _SERVICE_ENABLED=0
    return 1
}
module_socks_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s active=%s enabled=%s\\n' "${_rc}" "${_SERVICE_ACTIVE}" "${_SERVICE_ENABLED}"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"service rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 active=1 enabled=1" in cp.stdout,
        f"failed commit must restore service active and enabled state: {cp.stdout}",
    )


def test_runtime_vlquic_enable_restores_cross_artifact_state_after_config_failure():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}" "${_SVC_SYSTEMD_DIR}"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=old.example \
    -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" >/dev/null 2>&1 || exit 1
st_init >/dev/null 2>&1
st_set '.vlquic.enabled = false | .vlquic.domain = "old.example" | .vlquic.cert = "'"${WORK_DIR}"'/cert.pem" | .vlquic.key = "'"${WORK_DIR}"'/key.pem"' >/dev/null
st_persist >/dev/null 2>&1
printf 'old-config' > "${CONFIG_FILE}"
printf 'old-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
printf 'old-env' > "${_ARGO_ENV_FILE}"
printf 'old-tunnel' > "${WORK_DIR}/tunnel.yml"
printf 'nft:1080/tcp\\n' > "${_FW_RULES_FILE}"
printf '1080\\n' > "${_FW_PORTS_FILE}"
_fw_remove_rule() { return 0; }
_fw_open_port_backend() { _fw_mark_rule "$@"; }
fw_reconcile() { return 0; }
config_apply() {
    printf 'new-config' > "${CONFIG_FILE}"
    printf 'new-service' > "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
    printf 'new-env' > "${_ARGO_ENV_FILE}"
    printf 'new-tunnel' > "${WORK_DIR}/tunnel.yml"
    printf 'iptables:9999/tcp\\n' > "${_FW_RULES_FILE}"
    printf '9999\\n' > "${_FW_PORTS_FILE}"
    return 1
}
module_vlquic_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s config=%s state=%s service=%s env=%s tunnel=%s fw=%s ports=%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.vlquic.enabled')" \\
    "$(cat "${CONFIG_FILE}")" \\
    "$(jq -c . "${STATE_FILE}")" \\
    "$(cat "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service")" \\
    "$(cat "${_ARGO_ENV_FILE}")" \\
    "$(cat "${WORK_DIR}/tunnel.yml")" \\
    "$(cat "${_FW_RULES_FILE}")" \\
    "$(cat "${_FW_PORTS_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"VLESS-XHTTP-H3 enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false config=old-config state={" in cp.stdout
        and '"enabled":false' in cp.stdout
        and "service=old-service env=old-env tunnel=old-tunnel fw=nft:1080/tcp ports=1080" in cp.stdout,
        f"failed VLESS-XHTTP-H3 enable must restore all artifacts and state: {cp.stdout}",
    )


def test_runtime_cforigin_enable_failure_restores_precommit_defaults():
    from sandbox_runner import XraySandbox

    with XraySandbox() as sandbox:
        cp = subprocess.run(
            [
                "bash",
                "-lc",
                """
source ./xray_2go.sh
mkdir -p "${WORK_DIR}"
st_init >/dev/null 2>&1
st_set '.cforigin.enabled = false | .cforigin.protocol = null | .cforigin.path = null | .cforigin.listen = null | .cforigin.edge_port = null | .cforigin.domain = "old.example"' >/dev/null
st_persist >/dev/null 2>&1

_module_enable_commit() { return 1; }
module_cforigin_enable >/dev/null 2>&1
_rc=$?
printf 'rc=%s memory=%s/%s/%s/%s/%s/%s disk=%s/%s/%s/%s/%s/%s\\n' \\
    "${_rc}" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.enabled')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.protocol')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.path')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.listen')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.edge_port')" \\
    "$(printf '%s' "${_G_STATE}" | jq -r '.cforigin.domain')" \\
    "$(jq -r '.cforigin.enabled' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.protocol' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.path' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.listen' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.edge_port' "${STATE_FILE}")" \\
    "$(jq -r '.cforigin.domain' "${STATE_FILE}")"
""",
            ],
            cwd=ROOT,
            env=sandbox.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    assert_true(cp.returncode == 0, f"CF Origin enable rollback probe process failed: {cp.stdout}")
    assert_true(
        "rc=1 memory=false/null/null/null/null/old.example disk=false/null/null/null/null/old.example" in cp.stdout,
        f"failed CF Origin enable must restore pre-commit defaults and prior state: {cp.stdout}",
    )


def test_readme_documents_trojan_argo_capability():
    assert_true("Trojan" in README_TEXT, "README must document the Trojan Argo capability")
    assert_true(
        "Trojan + WS" in README_TEXT,
        "README must state that Trojan Argo is limited to WS transport",
    )
    assert_true(
        "8-128" in README_TEXT and "URL-safe" in README_TEXT,
        "README must document the Trojan password charset/length contract",
    )
    assert_true(
        "UUID" in README_TEXT and "回退" in README_TEXT,
        "README must document the UUID fallback when no Trojan password is stored",
    )




def test_ss2022_static_contract():
    assert_true('_plugin_write_ss2022()' in TEXT, "SS2022 builtin plugin writer is missing")
    assert_true('crypto_gen_ss2022_key' in TEXT and 'val_ss2022_key' in TEXT, "SS2022 key generation/validation helpers are missing")
    assert_true('2022-blake3-aes-256-gcm' in TEXT and '2022-blake3-aes-128-gcm' in TEXT, "SS2022 AES methods must be explicit")
    assert_true('.ss2022' in TEXT and '.ports.ss2022' in TEXT, "SS2022 state and centralized port fields are missing")
    assert_true('[ss2022]=unified_menu_ss2022' in TEXT and '[ss2022]=module_ss2022_enable' in TEXT and '[ss2022]=module_ss2022_update_port' in TEXT, "SS2022 registry metadata is incomplete")
    assert_true('module_registry_dispatch_common' in TEXT and 'module_dispatch()' in TEXT, "SS2022 common actions must use the registry dispatcher")

def test_ss2022_state_normalization_supplies_safe_defaults():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
printf 'enabled=%s method=%s port=%s listen=%s server=%s user=%s\\n' \\
    "$(st_get '.ss2022.enabled')" \\
    "$(st_get '.ss2022.method')" \\
    "$(st_get '.ports.ss2022')" \\
    "$(st_get '.ss2022.listen')" \\
    "$(st_get '.ss2022.server_key')" \\
    "$(st_get '.ss2022.user_key')"
""")
    assert_true(
        "enabled=false" in out
        and "method=2022-blake3-aes-256-gcm" in out
        and "port=8388" in out
        and "listen=0.0.0.0" in out
        and "server=" in out
        and "user=" in out,
        f"SS2022 normalization defaults are incomplete: {out}",
    )


def test_ss2022_key_generation_and_validation_match_method_sizes():
    out = run_bash("""
source ./xray_2go.sh
for method in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm; do
    key=$(crypto_gen_ss2022_key "$method")
    val_ss2022_key "$method" "$key" >/dev/null || exit 11
    printf '%s=ok\\n' "$method"
done
bad=$(printf 'not-a-base64-key')
if val_ss2022_key 2022-blake3-aes-256-gcm "$bad" >/dev/null 2>&1; then
    printf 'bad=accepted\\n'
else
    printf 'bad=rejected\\n'
fi
""")
    assert_true("2022-blake3-aes-128-gcm=ok" in out, f"AES-128 SS2022 key validation failed: {out}")
    assert_true("2022-blake3-aes-256-gcm=ok" in out, f"AES-256 SS2022 key validation failed: {out}")
    assert_true("bad=rejected" in out, f"invalid SS2022 key was accepted: {out}")


def test_ss2022_plugin_emits_xray_inbound_and_sip002_link():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
server=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
user=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
st_set '.ss2022.enabled = true | .ss2022.method = "2022-blake3-aes-256-gcm" | .ss2022.server_key = $server | .ss2022.user_key = $user | del(.ss2022.key_mode)' --arg server "$server" --arg user "$user" >/dev/null
_st_normalize_schema >/dev/null
platform_get_realip() { printf '203.0.113.10'; }
plugin_refresh_runtime >/dev/null
printf 'ports=%s\\n' "$(plugin_call ss2022 ports | paste -sd, -)"
printf 'inbound=%s\\n' "$(plugin_call ss2022 inbound | jq -c .)"
printf 'link=%s\\n' "$(plugin_call ss2022 link)"
""")
    lines = dict(line.split("=", 1) for line in out.splitlines() if "=" in line and line.split("=", 1)[0] in {"ports", "inbound", "link"})
    assert_true(lines.get("ports") == "8388/tcp,8388/udp", f"SS2022 port collector is wrong: {out}")
    inbound = __import__("json").loads(lines["inbound"])
    assert_true(inbound["protocol"] == "shadowsocks", f"wrong Xray protocol: {inbound}")
    assert_true(inbound["settings"]["method"] == "2022-blake3-aes-256-gcm", f"wrong SS2022 method: {inbound}")
    assert_true(inbound["settings"]["network"] == "tcp,udp", f"SS2022 network must support TCP and UDP: {inbound}")
    assert_true(len(inbound["settings"]["clients"]) == 1, f"SS2022 must expose one generated client: {inbound}")
    assert_true(inbound["settings"]["clients"][0]["email"] == "xray2go-ss2022", f"SS2022 client email missing: {inbound}")
    link = lines.get("link", "")
    assert_true(link.startswith("ss://") and "@203.0.113.10:8388" in link, f"SS2022 SIP002 link is malformed: {link}")
    payload = link[len("ss://"):].split("@", 1)[0]
    decoded = __import__("base64").urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()
    assert_true(decoded.startswith("2022-blake3-aes-256-gcm:") and decoded.count(":") == 2, f"SS2022 link must encode method/server/user keys: {decoded}")


def test_ss2022_single_key_profiles_generate_inbound_and_sip002_link():
    import base64
    import json
    from urllib.parse import unquote, urlsplit

    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled = false | .uuid = "00000000-0000-4000-8000-000000000000"'
        plugin_refresh_runtime
        platform_get_realip() { printf '%s' 2001:db8::10; }
        for selection in 1 2 3; do
            prompt() { printf -v "$2" '%s' "$selection"; }
            install_plan_ss2022_update_method >/dev/null
            _module_ss2022_enable_prepare
            install_plan_validate >/dev/null
            plugin_call ss2022 inbound | jq -c .
            plugin_call ss2022 link
        done
    ''', timeout=35)
    inbounds = [json.loads(line) for line in out.splitlines() if line.startswith('{')]
    links = [urlsplit(line) for line in out.splitlines() if line.startswith('ss://')]
    methods = (
        ('2022-blake3-aes-256-gcm', 32),
        ('2022-blake3-aes-128-gcm', 16),
        ('2022-blake3-chacha20-poly1305', 32),
    )
    assert len(inbounds) == len(links) == len(methods)
    for inbound, link, (method, key_bytes) in zip(inbounds, links, methods, strict=True):
        settings = inbound['settings']
        assert inbound['protocol'] == 'shadowsocks' and settings['network'] == 'tcp,udp'
        assert settings['method'] == method and 'clients' not in settings
        key = settings['password']
        assert len(base64.b64decode(key, validate=True)) == key_bytes
        assert link.username == method and unquote(link.password or '') == key
        assert link.hostname == '2001:db8::10' and link.port == 8388


def test_ss2022_runtime_config_uses_plugin_collector():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
server=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
user=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
st_set '.uuid = "00000000-0000-4000-8000-000000000000" | .argo.enabled = false | .ss2022.enabled = true | .ss2022.server_key = $server | .ss2022.user_key = $user' --arg server "$server" --arg user "$user" >/dev/null
plugin_refresh_runtime >/dev/null
config_synthesize | jq -c '{count:(.inbounds|length), ss:(.inbounds[] | select(.protocol == "shadowsocks") | {port,listen,method:.settings.method,network:.settings.network})}'
""")
    assert_true('"count":1' in out and '"ss":{"port":8388' in out and '"method":"2022-blake3-aes-256-gcm"' in out, f"SS2022 config synthesis failed: {out}")


def test_ss2022_enable_prepare_generates_one_key_by_default():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
st_set '.argo.enabled = false | .ss2022.enabled = false' >/dev/null
_module_ss2022_enable_prepare >/dev/null
method=$(st_get '.ss2022.method')
server=$(st_get '.ss2022.server_key')
user=$(st_get '.ss2022.user_key')
val_ss2022_key "$method" "$server" >/dev/null || exit 11
[[ -z "$user" ]] || exit 12
printf 'enabled=%s method=%s server_len=%s user_len=%s\\n' "$(st_get '.ss2022.enabled')" "$method" "$(printf '%s' "$server" | wc -c)" "$(printf '%s' "$user" | wc -c)"
""")
    assert_true("enabled=true" in out and "method=2022-blake3-aes-256-gcm" in out, f"SS2022 enable preparation failed: {out}")
    assert_true("server_len=44" in out and "user_len=0" in out, f"SS2022 generated key lengths are wrong: {out}")


def test_ss2022_install_plan_validation_accepts_enabled_state():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
server=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
user=$(head -c 32 /dev/zero | base64 | tr -d '\\n')
st_set '.uuid = "00000000-0000-4000-8000-000000000000" | .argo.enabled = false | .ss2022.enabled = true | .ss2022.server_key = $server | .ss2022.user_key = $user' --arg server "$server" --arg user "$user" >/dev/null
install_plan_validate >/dev/null
printf 'validated\\n'
""")
    assert_true("validated" in out, f"SS2022 install-plan validation rejected valid state: {out}")



def test_ss2022_transaction_rolls_back_state_and_disk_on_apply_failure():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        _ss2022_update_credentials install 2022-blake3-aes-256-gcm dual
        _module_ss2022_enable_prepare
        st_persist
        before=$(st_get '.ss2022')
        printf 'original' > "$CONFIG_FILE"
        config_apply() { printf 'failed change' > "$CONFIG_FILE"; return 37; }
        prompt() { printf -v "$2" '%s' 3; }
        if module_ss2022_update_method; then exit 1; fi
        [[ $(st_get '.ss2022') == "$before" ]]
        [[ $(jq '.ss2022' "$STATE_FILE") == "$before" ]]
        [[ $(<"$CONFIG_FILE") == original ]]
        if module_ss2022_regenerate_keys; then exit 1; fi
        [[ $(st_get '.ss2022') == "$before" ]]
        prompt() { printf -v "$2" '%s' 127.0.0.1; }
        if module_ss2022_update_listen; then exit 1; fi
        [[ $(st_get '.ss2022.listen') == 0.0.0.0 ]]
    ''', timeout=40)


def test_ss2022_draft_disable_and_reenable_preserves_legacy_credentials():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        _ss2022_update_credentials install 2022-blake3-aes-256-gcm dual
        _module_ss2022_enable_prepare
        before=$(st_get '.ss2022')
        install_plan_ss2022_toggle
        [[ $(st_get '.ss2022.enabled') == false ]]
        install_plan_ss2022_toggle
        [[ $(st_get '.ss2022') == "$before" ]]
    ''')


def test_ss2022_runtime_switch_and_rotation_preserve_profile():
    run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        _ss2022_update_credentials install 2022-blake3-aes-256-gcm dual
        _module_ss2022_enable_prepare
        st_persist
        plugin_refresh_runtime
        config_apply() { plugin_call ss2022 inbound > "$CONFIG_FILE"; }
        config_print_nodes() { :; }
        prompt() { printf -v "$2" '%s' "$selection"; }
        selection=3
        module_ss2022_update_method
        [[ $(st_get '.ss2022.key_mode') == single && -z $(st_get '.ss2022.user_key') ]]
        jq -e '.ss2022.key_mode == "single" and .ss2022.method == "2022-blake3-chacha20-poly1305"' "$STATE_FILE" >/dev/null
        jq -e '.settings | has("clients") | not' "$CONFIG_FILE" >/dev/null
        first=$(st_get '.ss2022.server_key')
        module_ss2022_regenerate_keys
        [[ $(st_get '.ss2022.server_key') != "$first" && -z $(st_get '.ss2022.user_key') ]]
        selection=5
        module_ss2022_update_method
        [[ $(st_get '.ss2022.key_mode') == dual ]]
        jq -e '.settings.method == "2022-blake3-aes-128-gcm" and (.settings.clients | length == 1)' "$CONFIG_FILE" >/dev/null
        if _ss2022_update_credentials install 2022-blake3-chacha20-poly1305 dual; then exit 1; fi
    ''', timeout=40)


def test_port_update_starts_transaction_before_state_mutation():
    out = run_bash("""
source ./xray_2go.sh
_G_STATE="$_STATE_DEFAULT"
_st_normalize_schema >/dev/null
rm -f "$STATE_FILE"
port_mgr_in_use() { return 1; }
port_mgr_in_use_udp() { return 1; }
fw_reconcile() { return 0; }
config_print_nodes() { :; }
prompt() { printf -v "$2" '%s' 10006; }
config_apply() { return 37; }
module_ss2022_update_port >/dev/null 2>&1; rc=$?
printf 'fail_rc=%s mem=%s file=%s\\n' "$rc" "$(port_of ss2022)" "$([ -f "$STATE_FILE" ] && printf yes || printf no)"
config_apply() { return 0; }
prompt() { printf -v "$2" '%s' 10007; }
_msg_file=$(mktemp)
module_ss2022_update_port >"$_msg_file" 2>&1; rc=$?
printf 'ok_rc=%s mem=%s disk=%s\\n' "$rc" "$(port_of ss2022)" "$(jq -r '.ports.ss2022' "$STATE_FILE")"
grep -q 'Shadowsocks 2022 端口已更新: 10007（TCP/UDP）' "$_msg_file" && printf 'msg=ok\\n'; rm -f "$_msg_file"
""")
    assert_true("fail_rc=1 mem=8388 file=no" in out, f"port update must roll back in-memory state even without state.json: {out}")
    assert_true("ok_rc=0 mem=10007 disk=10007" in out, f"port update must persist the new port: {out}")
    assert_true("msg=ok" in out, f"port update message should name the module and protocol: {out}")


def test_transaction_refreshes_state_after_lock():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init || exit 1
        st_set '.cforigin.path="/before" | .cforigin.domain="before.example.net"'
        st_persist || exit 1
        update() { st_set "$1" && st_persist; }
        (_transaction_run "first edit" update '.cforigin.path="/first"') || exit 1
        _transaction_run "second edit" update '.cforigin.domain="second.example.net"' || exit 1
        jq -e '.cforigin.path=="/first" and .cforigin.domain=="second.example.net"' "$STATE_FILE" >/dev/null || exit 1
        printf 'BOTH_EDITS_RETAINED\n'
    ''', timeout=30)
    assert 'BOTH_EDITS_RETAINED' in out, out


def test_cforigin_field_save_rolls_back():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init || exit 1
        st_set '.cforigin.enabled=true | .cforigin.path="/before"' || exit 1
        st_persist || exit 1
        printf 'old config' > "$CONFIG_FILE"
        prompt() { printf -v "$2" '%s' '/after'; }
        config_apply() { printf 'new config' > "$CONFIG_FILE" && printf 'APPLIED\n'; }
        st_persist() { return 1; }
        if module_cforigin_update_path; then exit 1; fi
        [[ $(st_get '.cforigin.path') == /before ]] || exit 1
        jq -e '.cforigin.path=="/before"' "$STATE_FILE" >/dev/null || exit 1
        [[ $(<"$CONFIG_FILE") == 'old config' ]] || exit 1
        printf 'FIELD_SAVE_ROLLED_BACK\n'
    ''', timeout=30)
    assert 'APPLIED' in out and 'FIELD_SAVE_ROLLED_BACK' in out, out


def test_argo_runtime_publish_restores_failed_token_switch():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init || exit 1
        st_set '.argo.enabled=true | .argo.domain="argo.fixture.invalid" | .ports.argo=29991' || exit 1
        st_persist || exit 1
        printf '%s' '{"TunnelID":"old-id"}' > "$WORK_DIR/tunnel.json"
        printf 'old yaml' > "$WORK_DIR/tunnel.yml"
        prompt_secret() { printf -v "$2" '%0120d' 1; }
        svc_apply_tunnel() {
            [[ -n $(st_get '.argo.token') && ! -e "$WORK_DIR/tunnel.json" ]] || return 1
            printf 'TOKEN_SELECTED\n'
        }
        config_apply() { return 0; }
        svc_exec_mut() { [[ $1 != restart ]]; }
        if module_argo_update_action auth; then exit 1; fi
        [[ -z $(st_get '.argo.token') ]] || exit 1
        jq -e '.argo.token == null' "$STATE_FILE" >/dev/null || exit 1
        [[ $(<"$WORK_DIR/tunnel.yml") == 'old yaml' && -f "$WORK_DIR/tunnel.json" ]] || exit 1
        printf 'TOKEN_SWITCH_ROLLED_BACK\n'
    ''', timeout=35)
    assert 'TOKEN_SELECTED' in out and 'TOKEN_SWITCH_ROLLED_BACK' in out, out


def test_cforigin_plan_defers_certificate_issuance():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init || exit 1
        st_set '.argo.enabled=false | .cforigin.enabled=true' || exit 1
        plugin_refresh_runtime || exit 1
        prompt() {
            case "$2" in
                _domain) printf -v "$2" '%s' 'origin.fixture.invalid' ;;
                _email) printf -v "$2" '%s' 'admin@fixture.invalid' ;;
                _c) printf -v "$2" '%s' "$confirm" ;;
                *) printf -v "$2" '%s' '' ;;
            esac
        }
        prompt_secret() { printf -v "$2" '%s' 'fixture-token'; }
        acme_issue_cf_token_to_state() {
            printf 'ISSUER_CALLED\n'
            [[ $confirm == y ]] || exit 1
            local dir="$_CERT_DIR/$2"
            mkdir -p "$dir" || return 1
            printf 'replacement' > "$dir/fullchain.pem"
            printf 'private fixture' > "$dir/privkey.pem"
            [[ $issue_result == ok ]] || return 1
            openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$2" \
                -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" >/dev/null 2>&1 || return 1
            st_set '.cforigin.cert = $c | .cforigin.key = $k' --arg c "$dir/fullchain.pem" --arg k "$dir/privkey.pem"
        }
        _install_check_port_conflicts() { return 0; }
        module_xray_install_core() { printf 'CORE_CALLED\n'; }
        config_print_nodes() { return 0; }
        confirm=n
        install_plan_cforigin_update_cert || exit 1
        [[ -z $(st_get '.cforigin.cert') ]] || exit 1
        if install_wizard_confirm; then exit 1; fi
        confirm=y
        issue_result=fail
        dir="$_CERT_DIR/origin.fixture.invalid"
        mkdir -p "$dir" || exit 1
        printf 'existing certificate' > "$dir/fullchain.pem"
        if install_wizard_confirm; then exit 1; fi
        [[ $(<"$dir/fullchain.pem") == 'existing certificate' && ! -e "$dir/privkey.pem" ]] || exit 1
        [[ $(st_get '.cforigin.domain') == origin.fixture.invalid ]] || exit 1
        issue_result=ok
        install_wizard_confirm || exit 1
    ''', timeout=45)
    assert out.count('ISSUER_CALLED') == 2 and out.count('CORE_CALLED') == 1, out


def test_direct_h3_certificate_validation_and_rollback():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        mkdir -p "$WORK_DIR"
        for domain in old.fixture.invalid new.fixture.invalid; do
            openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$domain" \
                -keyout "$WORK_DIR/$domain.key" -out "$WORK_DIR/$domain.crt" >/dev/null 2>&1
        done
        old=old.fixture.invalid
        new=new.fixture.invalid
        st_set '.vlquic.enabled=true | .vlquic.domain=$d | .vlquic.cert=$c | .vlquic.key=$k' \
            --arg d "$old" --arg c "$WORK_DIR/$old.crt" --arg k "$WORK_DIR/$old.key"
        st_persist
        printf 'old-config' > "$CONFIG_FILE"
        prompt() { IFS= read -r "$2"; }
        prompt_secret() { IFS= read -r "$2"; }
        fw_reconcile() { return 0; }
        config_print_nodes() { return 0; }
        config_apply() {
            printf 'CONFIG_APPLY_CALLED\n'
            printf 'new-config' > "$CONFIG_FILE"
            [[ $apply_result == ok ]]
        }
        update_cert() {
            module_vlquic_update_cert <<< "$new"$'\n4\n'"$WORK_DIR/$1.crt"$'\n'"$WORK_DIR/$2.key"
        }
        apply_result=ok
        if update_cert "$old" "$old"; then exit 1; fi
        if update_cert "$new" "$old"; then exit 1; fi
        apply_result=fail
        if update_cert "$new" "$new"; then exit 1; fi
        [[ $(st_get '.vlquic.domain') == "$old" && $(<"$CONFIG_FILE") == old-config ]]
        jq -e --arg d "$old" '.vlquic.domain == $d' "$STATE_FILE" >/dev/null
        apply_result=ok
        update_cert "$new" "$new"
        jq -e --arg d "$new" '.vlquic.domain == $d' "$STATE_FILE" >/dev/null
    ''', timeout=36)
    assert out.count('CONFIG_APPLY_CALLED') == 2, out


def test_direct_h3_plan_defers_certificate_issuance():
    out = run_bash(r'''
        source ./xray_2go.sh
        set -e
        st_init
        st_set '.argo.enabled=false | .vlquic.enabled=true'
        plugin_refresh_runtime
        clear() { :; }
        prompt() {
            case "$2" in
                _domain) printf -v "$2" '%s' h3.fixture.invalid ;;
                _m) printf -v "$2" '%s' 3 ;;
                _email) printf -v "$2" '%s' admin@fixture.invalid ;;
                _c) printf -v "$2" '%s' "$confirm" ;;
            esac
        }
        acme_issue_http01() {
            printf 'H3_ISSUER_CALLED\n'
            [[ $confirm == y ]] || exit 1
            local dir="$_CERT_DIR/$1"
            mkdir -p "$dir" || return 1
            printf 'replacement' > "$dir/fullchain.pem"
            printf 'fixture key' > "$dir/privkey.pem"
            [[ $issue_result == ok ]] || return 1
            openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" \
                -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" >/dev/null 2>&1 || return 1
            st_set '.vlquic.cert = $c | .vlquic.key = $k' --arg c "$dir/fullchain.pem" --arg k "$dir/privkey.pem"
        }
        _install_check_port_conflicts() { return 0; }
        module_xray_install_core() { printf 'CORE_CALLED\n'; }
        config_print_nodes() { return 0; }
        confirm=n
        install_plan_vlquic_update_cert
        [[ -z $(st_get '.vlquic.cert') ]]
        if install_wizard_confirm; then exit 1; fi
        confirm=y
        issue_result=fail
        dir="$_CERT_DIR/h3.fixture.invalid"
        mkdir -p "$dir"
        printf 'existing certificate' > "$dir/fullchain.pem"
        if install_wizard_confirm; then exit 1; fi
        [[ $(<"$dir/fullchain.pem") == 'existing certificate' && ! -e "$dir/privkey.pem" ]]
        [[ $(st_get '.vlquic.domain') == h3.fixture.invalid ]]
        issue_result=ok
        install_wizard_confirm
    ''', timeout=45)
    assert out.count('H3_ISSUER_CALLED') == 2 and out.count('CORE_CALLED') == 1, out


def test_draft_and_runtime_reuse_transport_and_port_input_rules():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        st_set '.ff.enabled = false | .ff.protocol = "ws" |
                .cforigin.protocol = "xhttp" | .cforigin.edge_h3 = true | .ports.argo = 12345'
        prompt() { IFS= read -r "$2"; }
        before=$_G_STATE
        if install_plan_ff_update_mode <<< '4'; then exit 1; fi
        [[ "$_G_STATE" == "$before" ]] || exit 2
        if install_plan_cforigin_update_protocol <<< '9'; then exit 3; fi
        [[ "$_G_STATE" == "$before" ]] || exit 4
        install_plan_cforigin_update_protocol <<< '2' || exit 5
        [[ $(st_get '.cforigin.protocol') == httpupgrade && $(st_get '.cforigin.edge_h3') == false ]] || exit 6
        port_mgr_in_use() { return 1; }
        port_mgr_random_proto() { printf '%s' 23456; }
        install_plan_argo_update_port <<< '' || exit 7
        [[ $(port_of argo) == 12345 ]] || exit 8
        _commit_port_change() { [[ $1 == cforigin && $2 == 23456 ]]; }
        cforigin_print_cloudflare_hint() { :; }
        module_cforigin_update_port <<< '' || exit 9
    """)


def test_draft_listen_and_ports_share_input_results():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        prompt() { IFS= read -r "$2"; }
        for module in vltcp socks http cforigin vlquic ss2022; do
            before=$_G_STATE
            if "install_plan_${module}_update_listen" <<< 'invalid address'; then exit 1; fi
            "install_plan_${module}_update_listen" <<< '' || exit 2
            [[ $_G_STATE == "$before" ]] || exit 3
            "install_plan_${module}_update_listen" <<< '127.0.0.1' || exit 4
            [[ $(st_get '.[$id].listen' --arg id "$module") == 127.0.0.1 ]] || exit 5
        done
        port_mgr_in_use() { [[ $1 == 23456 ]]; }
        port_mgr_in_use_udp() { [[ $1 == 23457 ]]; }
        before=$_G_STATE
        if install_plan_ff_update_port <<< 'invalid'; then exit 6; fi
        [[ $_G_STATE == "$before" ]] || exit 7
        install_plan_ff_update_port <<< '23456' || exit 8
        install_plan_vlquic_update_port <<< '23457' || exit 9
        [[ $(port_of ff) == 23456 && $(port_of vlquic) == 23457 ]] || exit 10
        for port in 23456 23457; do
            output=$(install_plan_ss2022_update_port <<< "$port" 2>&1) || exit 11
            [[ $output == *"TCP/UDP/$port 已被占用"* ]] || exit 12
        done
    """)


def test_argo_cleanup_and_host_restoration_report_failure():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        st_set '.argo.enabled = true'
        svc_exec_mut() { return 1; }
        svc_exec() { [[ $1 == status ]]; }
        svc_is_enabled() { return 0; }
        _module_disable_commit() { return 0; }
        if module_argo_disable_inner; then exit 1; fi
        if module_argo_uninstall_inner; then exit 2; fi
        [[ $(st_get '.argo.enabled') == true ]] || exit 3
        mkdir -p "$WORK_DIR" "$(dirname "$_SYSCTL_FILE")"
        printf 'fixture\n' > "$_HOSTS_BAK"
        cp() { return 1; }
        if lifecycle_rollback_hosts; then exit 4; fi
        printf '# xray2go managed - do not edit manually\n' > "$_SYSCTL_FILE"
        rm() { return 1; }
        if lifecycle_rollback_sysctl; then exit 5; fi
    """)


def test_argo_unchanged_credentials_skip_apply_and_health_probe():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        st_set '.argo.enabled = true | .argo.protocol = "ws" |
                .argo.auth_protocol = "trojan" | .argo.trojan_password = "fixture_password"'
        prompt_secret() { IFS= read -r "$2"; }
        argo_apply_fixed_tunnel_from_state() { exit 1; }
        argo_check_health() { exit 2; }
        for action in auth trojan_password; do
            module_argo_update_action "$action" <<< '' || exit 3
        done
    """)


def test_xhttp_profile_writers_share_reserved_fields():
    run_bash(r"""
        source ./xray_2go.sh
        st_init
        for module in argo reality ff vlquic cforigin; do
            before=$_G_STATE
            for profile in '{"server":{"path":"/elsewhere"}}' '{"client":{"mode":"auto"}}' '{"client":{"xhttpModeH3":true}}'; do
                if "_${module}_xhttp_set_profile" 0 "$profile"; then exit 1; fi
                [[ "$_G_STATE" == "$before" ]] || exit 2
            done
            "_${module}_xhttp_set_profile" 0 '{"server":{"xPaddingBytes":"128-768"}}' || exit 3
        done
    """)


def test_port_prompt_distinguishes_eof_from_blank():
    out = run_bash(r'''
        source ./xray_2go.sh
        port_mgr_random_proto() { printf 'RANDOM_CALLED\n' >&2; printf 29991; }
        port_mgr_in_use() { return 1; }
        prompt() { return 1; }
        if _menu_select_port tcp selected; then exit 1; fi
        [[ ! -v selected ]] || exit 1
        prompt() { printf -v "$2" '%s' ''; }
        _menu_select_port tcp selected || exit 1
        [[ $selected == 29991 ]] || exit 1
        printf 'BLANK_SELECTED_RANDOM\n'
    ''', timeout=30)
    assert out.count('RANDOM_CALLED') == 1 and 'BLANK_SELECTED_RANDOM' in out, out


def test_management_action_pauses_once():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init
        st_set '.cforigin.enabled=false | .cforigin.protocol="ws"'
        st_persist
        _manage_module_entry_check() { return 0; }
        _unified_runtime_status_for() { return 0; }
        clear() { :; }
        prompt() { IFS= read -r "$2"; }
        _pause() { printf 'ACTION_PAUSE\n'; }
        module_cforigin_uninstall() { printf 'UNINSTALL_RAN\n'; }
        unified_menu_cforigin runtime <<< $'2\n3\n2\n9\nu\nn\n0'
        jq -e '.cforigin.enabled == false and .cforigin.protocol == "xhttp"' "${STATE_FILE}" >/dev/null || exit 1
        printf 'CHECK_STATUS\n'
        module_dispatch cforigin update_protocol <<< '3' || exit 1
        printf 'UPDATE_RETURNED_SUCCESS\n'
    ''', timeout=30)
    menu_out, _, action_out = out.partition('CHECK_STATUS')
    assert menu_out.count('ACTION_PAUSE') == 3, menu_out
    assert '无效选项' in menu_out and 'UNINSTALL_RAN' not in menu_out, menu_out
    assert 'UPDATE_RETURNED_SUCCESS' in action_out and 'ACTION_PAUSE' not in action_out, action_out


def test_menu_back_redraws_parent_without_pause():
    out = run_bash(r'''
source ./xray_2go.sh
st_init >/dev/null
st_set '.argo.protocol="xhttp"'
clear() { :; }
check_xray_install() { return 0; }
check_xray() { return 0; }
_manage_module_entry_check() { :; }
_pause() { printf 'UNEXPECTED_PAUSE\n'; }
prompt() { printf 'page=%s\n' "$1"; IFS= read -r "$2"; }
(menu <<< $'2\nx\n0\n0\n0')
(install_plan_menu <<< $'1\n0\n0')
unified_menu_argo runtime </dev/null
    ''')
    pages = re.findall(r'^page=(.*)$', out, re.MULTILINE)
    expected = ['输入编号或按键', '(0-9/x/r/h/v/u)', '(0-7)', '(0-9/x/r/h/v/u)',
                '输入编号或按键', '(0-13)', '(0-9/x)', '(0-13)', '(0-9/x/r/h/v/u)']
    assert_true(len(pages) == len(expected) and all(hint in page for hint, page in zip(expected, pages)), pages)
    assert_true('UNEXPECTED_PAUSE' not in out, out)


def test_console_redraws_after_deployment_exit_and_pauses_once_for_results():
    out = run_bash(r'''
        source ./xray_2go.sh
        st_init >/dev/null
        _menu_collect_status() { _MENU_XI=0; _MENU_CX=1; }
        _menu_render() { echo console; }
        install_wizard_render() { echo wizard; }
        install_plan_render_summary() { echo advanced; }
        install_wizard_reality() { echo deployed; }
        module_xray_upgrade() { echo upgraded; }
        module_config_update_shortcut() { echo update_failed; return 1; }
        prompt() { IFS= read -r "$2"; }
        _pause() { echo feedback; }
        menu <<< $'d\n0\nd\n3\n0\nd\n1\nx\ns\n0'
    ''')
    events = re.findall(r'^(console|wizard|advanced|deployed|upgraded|update_failed|feedback)$', out, re.M)
    assert_true(events == ['console', 'wizard', 'console', 'wizard', 'advanced', 'console',
                           'wizard', 'deployed', 'feedback', 'console', 'upgraded', 'feedback',
                           'console', 'update_failed', 'feedback', 'console'], events)


def test_main_menu_status_and_key_dispatch():
    out = run_bash(r'''
source ./xray_2go.sh
st_init >/dev/null
clear() { :; }
_pause() { :; }
prompt() { IFS= read -r "$2"; }
check_xray() { return 1; }
check_xray_install() { return 1; }
printf '%s\n' FIRST
_menu_collect_status
_menu_render
check_xray() { return 0; }
check_xray_install() { return 0; }
check_argo() { printf running; }
st_set '.argo.enabled=true | .argo.protocol="xhttp" | .argo.domain="long-argo-domain-for-terminal-width-check.example.com" |
    .http.enabled=true | .http.listen="2001:db8:1234:5678:9101:abcd:eded:42" | .ports.http=61107'
printf '%s\n' INSTALLED
_menu_collect_status
_menu_render
printf '%s\n' ROUTES
_menu_render() { :; }
module_dispatch() { printf 'route=%s\n' "$*"; }
(menu <<< $'1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\nd\nu\ns\nx\n12\n0')
module_dispatch() { IFS= read -r input; printf 'action stdin=%s\n' "$input"; }
_menu_select_action s <<< original-input
    ''', timeout=70)
    plain = re.sub(r'\x1b\[[0-9;]*m', '', out)
    first, installed = plain.split('FIRST\n', 1)[1].split('INSTALLED\n', 1)
    installed, routes = installed.split('ROUTES\n', 1)
    assert_true('未安装' in first and 'd. 开始部署（快速向导）' in first, first)
    assert_true('Xray-2go 控制台' in installed and '运行中' in installed, installed)
    for detail in ['long-argo-domain-for-terminal-width-check.example.com', '2001:db8:1234:5678:9101:abcd:eded:42', '61107']:
        assert_true(detail in installed, installed)
    for label in ['连接', '入站管理', '维护', '1. 查看节点与连接提示', '2. Argo 固定隧道', '10. Shadowsocks 2022', '11. 更新 UUID', 'x. 升级 Xray 内核', 'u. 卸载整套 Xray-2go']:
        assert_true(label in installed, installed)
    overview = installed.split('连接', 1)[0]
    assert_true('Reality' not in overview and '未启用' not in overview, overview)
    expected = ['nodes show', 'argo', 'reality', 'vltcp', 'vlquic', 'ff', 'cforigin',
                'socks', 'http', 'ss2022', 'config update_uuid', 'xray install',
                'xray uninstall', 'config update_shortcut', 'xray upgrade']
    actual = re.findall(r'^route=(.*)$', routes, re.MULTILINE)
    assert_true(actual == expected, f'main menu routes: {actual!r}')
    assert_true('无效选项' in routes and '已退出' in routes, routes)
    assert_true('action stdin=original-input' in routes, routes)


def _function_body(name):
    start = TEXT.index(f"{name}()")
    end = TEXT.index("\n}\n", start)
    return TEXT[start:end]


def test_ss2022_updates_use_transactional_state_commit():
    method_body = _function_body("module_ss2022_update_method")
    keys_body = _function_body("module_ss2022_regenerate_keys")
    listen_body = _function_body("module_update_listen_action")
    select_body = _function_body("_ss2022_select_method")
    credentials_body = _function_body("_module_ss2022_apply_credentials")
    assert_true("_ss2022_select_method runtime" in method_body, "SS2022 method updates must select the runtime path")
    assert_true("_module_ss2022_apply_credentials" in select_body, "SS2022 runtime method selection must use the shared credential update")
    assert_true("_module_ss2022_apply_credentials" in keys_body, "SS2022 key rotation must use the shared runtime credential update")
    assert_true("_module_update_state_transaction" in credentials_body, "SS2022 credential updates must use the transactional state helper")
    assert_true("_module_update_listen_transaction" in listen_body, "listen updates must use the transactional state helper")
    for body in (method_body, keys_body, listen_body):
        assert_true("_module_persist_after_optional_apply" not in body, "SS2022 updates must not use the non-transactional persistence helper")


def test_ss2022_port_updates_cover_tcp_and_udp():
    assert_true("port_mgr_in_use_both" in TEXT, "dual-protocol port occupancy helper is missing")
    assert_true("port_mgr_random_proto" in TEXT, "random port selection helper is missing")
    assert_true("module_update_port_action ss2022 both" in TEXT, "SS2022 port updates must check TCP and UDP")

    out = run_bash("""
source ./xray_2go.sh
port_mgr_in_use() { [ "$1" = "10001" ]; }
port_mgr_in_use_udp() { [ "$1" = "10002" ]; }
if port_mgr_in_use_both 10001; then printf 'tcp=busy\\n'; else printf 'tcp=free\\n'; fi
if port_mgr_in_use_both 10002; then printf 'udp=busy\\n'; else printf 'udp=free\\n'; fi
if port_mgr_in_use_both 10003; then printf 'free=busy\\n'; else printf 'free=free\\n'; fi
_shuf_state=$(mktemp)
printf '0' > "$_shuf_state"
shuf() {
    _n=$(cat "$_shuf_state")
    _n=$(( _n + 1 ))
    printf '%s' "$_n" > "$_shuf_state"
    case "$_n" in
        1) printf '10001' ;;
        2) printf '10002' ;;
        *) printf '10003' ;;
    esac
}
port_mgr_in_use() { [ "$1" = "10001" ]; }
port_mgr_in_use_udp() { [ "$1" = "10002" ]; }
printf 'random=%s\\n' "$(port_mgr_random_proto both)"
rm -f "$_shuf_state"
""")
    assert_true("tcp=busy" in out and "udp=busy" in out and "free=free" in out and "random=10003" in out, f"dual-protocol occupancy/random check is wrong: {out}")


def test_ss2022_key_generation_rejects_empty_output():
    out = run_bash("""
source ./xray_2go.sh
tmp=$(mktemp -d)
cat > "$tmp/openssl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 755 "$tmp/openssl"
if PATH="$tmp:/usr/bin:/bin" crypto_gen_ss2022_key 2022-blake3-aes-256-gcm >/dev/null 2>&1; then
    printf 'empty=accepted\\n'
else
    printf 'empty=rejected\\n'
fi
rm -rf "$tmp"
""")
    assert_true("empty=rejected" in out, f"SS2022 key generation accepted empty openssl output: {out}")


def test_common_module_actions_are_owned_by_registry_metadata():
    registry_body = TEXT[TEXT.index("_MODULE_IDS="):TEXT.index("module_summary()")]
    dispatch_body = TEXT[TEXT.index("module_dispatch()"):TEXT.index("# 交互输入端口")]
    assert_true('_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http ss2022"' in registry_body, "module IDs must have one canonical registry assignment")
    for name in ["_MODULE_LABELS", "_MODULE_MENU_FN", "_MODULE_ENABLE_FN", "_MODULE_DISABLE_FN", "_MODULE_UNINSTALL_FN", "_MODULE_UPDATE_PORT_FN", "_MODULE_UPDATE_LISTEN_FN"]:
        assert_true(name in registry_body, f"module registry metadata is missing: {name}")
    expected = {
        "argo": ["unified_menu_argo", "module_argo_enable", "module_argo_disable", "module_argo_uninstall", "module_argo_update_port"],
        "ff": ["unified_menu_freeflow", "module_ff_enable", "module_ff_disable", "module_ff_uninstall", "module_ff_update_port"],
        "reality": ["unified_menu_reality", "module_reality_enable", "module_reality_disable", "module_reality_uninstall", "module_reality_update_port"],
        "vltcp": ["unified_menu_vltcp", "module_vltcp_enable", "module_vltcp_disable", "module_vltcp_uninstall", "module_vltcp_update_port", "module_vltcp_update_listen"],
        "vlquic": ["unified_menu_vlquic", "module_vlquic_enable", "module_vlquic_disable", "module_vlquic_uninstall", "module_vlquic_update_port", "module_vlquic_update_listen"],
        "cforigin": ["unified_menu_cforigin", "module_cforigin_enable", "module_cforigin_disable", "module_cforigin_uninstall", "module_cforigin_update_port", "module_cforigin_update_listen"],
        "socks": ["unified_menu_socks", "module_socks_enable", "module_socks_disable", "module_socks_uninstall", "module_socks_update_port", "module_socks_update_listen"],
        "http": ["unified_menu_http", "module_http_enable", "module_http_disable", "module_http_uninstall", "module_http_update_port", "module_http_update_listen"],
        "ss2022": ["unified_menu_ss2022", "module_ss2022_enable", "module_ss2022_disable", "module_ss2022_uninstall", "module_ss2022_update_port", "module_ss2022_update_listen"],
    }
    for module, handlers in expected.items():
        for handler in handlers:
            assert_true(handler in registry_body, f"registry entry missing for {module}: {handler}")
    assert_true("module_registry_dispatch_common" in dispatch_body, "common module actions must use registry dispatch")
    for token in ["argo:menu)", "argo:restart)", "argo:show)", "argo:enable)", "argo:disable)", "argo:uninstall)", "argo:update_port)", "socks:menu)", "http:enable)"]:
        assert_true(token not in dispatch_body, f"common action remains hardcoded in module_dispatch: {token}")

def main():
    from probe_matrix import run_probe_matrix

    report = run_probe_matrix(Path(__file__))
    if report["failed"]:
        for failure in report["failed"]:
            print(f"FAIL {failure['name']} [{failure['category']}]\\n{failure['output']}")
        raise SystemExit(1)
    for result in report["results"]:
        print(f"PASS {result['name']}")


if __name__ == "__main__":
    main()
