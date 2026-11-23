-- KWin's clientArea leaves room for Plasma panels when setting frameGeometry.
-- https://develop.kde.org/docs/plasma/kwin/api/
local place_script = [[
var area;
var tries = 20;
function placePanes() {
    var windows = workspace.stackingOrder || workspace.clientList();
    for (var i = 0; i < windows.length; i++) {
        var w = windows[i];
        var role = panes[w.caption];
        if (w.pid !== pid || (role !== "host" && role !== "guest")) continue;
        if (!area) {
            var anchor = w;
            for (var j = 0; j < windows.length; j++) {
                var other = windows[j];
                if (other.pid === pid && other.caption.indexOf("War - ") === 0) {
                    anchor = other;
                    break;
                }
            }
            area = workspace.clientArea(KWin.MaximizeArea, anchor);
            var screens = workspace.screens || [];
            for (var j = 0; output && j < screens.length; j++) {
                if (screens[j].name === output) {
                    area = workspace.clientArea(KWin.MaximizeArea, screens[j], workspace.currentDesktop);
                    break;
                }
            }
        }
        var half = Math.floor(area.width / 2);
        var width = Math.max(1, half - 16);
        var height = Math.max(1, Math.min(area.height - 100, Math.floor(width * 9 / 16)));
        w.setMaximize(false, false);
        w.frameGeometry = {x: area.x + 8 + (role === "guest" ? half : 0),
                           y: area.y + 40, width: width, height: height};
        delete panes[w.caption];
    }
    if (!Object.keys(panes).length || --tries === 0) timer.stop();
}
var timer = new QTimer();
timer.interval = 100;
timer.timeout.connect(placePanes);
timer.start();
placePanes();
]]

-- Keep the KWin script loaded for its two-second window placement retry loop.
local run_script = [=[(
unset LD_PRELOAD LD_LIBRARY_PATH
command -v busctl >/dev/null || { echo "War pane placement requires busctl" >&2; exit 1; }
script=$(mktemp "${XDG_RUNTIME_DIR:?}/war-panes-XXXXXXXX") || exit 1
name=${script##*/}
kwin() { busctl --user --timeout=2s call org.kde.KWin "$@"; }
cleanup() {
    kwin /Scripting org.kde.kwin.Scripting unloadScript s "$name" >/dev/null
    rm -f -- "$script"
}
trap cleanup EXIT
cat > "$script" <<'WAR_KWIN_JS'
%s
WAR_KWIN_JS
reply=$(kwin /Scripting org.kde.kwin.Scripting loadScript ss "$script" "$name") || exit 1
id=${reply#i }
case "$id" in ''|*[!0-9]*) exit 1 ;; esac
kwin "/Scripting/Script$id" org.kde.kwin.Script run ||
    kwin "/$id" org.kde.kwin.Script run || exit 1
sleep 2
) </dev/null >/dev/null &]=]

function WAR.place_kwin_panes(layout)
    local entries, pid = {}, nil
    for _, pane in ipairs(layout) do
        local owner, role = pane.title:match("^War pane (%d+)%-%d+%-(%a+)$")
        if not owner or (pid and owner ~= pid) or role ~= pane.role
            or (role ~= "host" and role ~= "guest") then
            return
        end
        pid = owner
        entries[#entries + 1] = string.format('"%s":"%s"', pane.title, role)
    end
    if not pid then return end
    local output = layout[1].output or ""
    if not output:match("^[%w_.%-]*$") then output = "" end
    local data = string.format('var pid = %s, output = "%s", panes = {%s};\n',
        pid, output, table.concat(entries, ","))
    os.execute(string.format(run_script, data .. place_script))
end
