// Cargo Earth installer: installs, updates or removes the Cargo Earth mod and its helper
// for BeamNG.drive with BeamNG.Earth. Build for Windows with:
//
//	GOOS=windows GOARCH=amd64 go build -ldflags "-s -w" -o CargoEarthSetup.exe .
//	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-s -w" -o CargoEarthSetup-linux-x86_64 .
//
// Double-click it for a short menu, or run it from a command prompt with options (see -help).
package main

import (
	"archive/zip"
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	repo       = "themazzy/cargo-earth"
	addonID    = "cargo-earth-helper"
	helperPort = 47821
	modMarker  = "lua/ge/extensions/cargoEarth/core.lua"
	userAgent  = "cargo-earth-installer"
)

// set with -ldflags "-X main.buildVersion=0.10.0"; the release the installer was built for
var buildVersion = "dev"

type options struct {
	version, userFolder, zipPath, helperPath   string
	modOnly, helperOnly, skipPython, uninstall bool
	dryRun, noPause, deleteSave, yes           bool
}

var opt options
var stdin = bufio.NewReader(os.Stdin)
var local string // Windows LOCALAPPDATA or Linux XDG data directory

func say(format string, a ...any)  { fmt.Printf("  "+format+"\n", a...) }
func step(text string)             { fmt.Printf("\n== %s\n", text) }
func warn(format string, a ...any) { fmt.Printf("  ! "+format+"\n", a...) }

// doIt runs action unless this is a dry run.
func doIt(what string, action func() error) error {
	if opt.dryRun {
		say("[dry run] %s", what)
		return nil
	}
	return action()
}

func main() {
	flag.StringVar(&opt.version, "version", "", "release to install, e.g. 0.10.0 (default: the latest release)")
	flag.StringVar(&opt.userFolder, "user-folder", "", "BeamNG user folder (default: found automatically)")
	flag.StringVar(&opt.zipPath, "zip", "", "use this mod ZIP instead of downloading")
	flag.StringVar(&opt.helperPath, "helper", "", "use this helper .py instead of downloading")
	flag.BoolVar(&opt.modOnly, "mod-only", false, "install only the mod")
	flag.BoolVar(&opt.helperOnly, "helper-only", false, "install only the helper")
	flag.BoolVar(&opt.skipPython, "skip-python", false, "don't install the helper's Python libraries")
	flag.BoolVar(&opt.uninstall, "uninstall", false, "remove the mod ZIP, the helper and its add-on entry (saves are kept)")
	flag.BoolVar(&opt.dryRun, "dry-run", false, "show what would happen, change nothing")
	flag.BoolVar(&opt.noPause, "no-pause", false, "don't wait for Enter before closing")
	flag.BoolVar(&opt.deleteSave, "delete-save", false, "delete the Cargo Earth career save and its backups (asks first)")
	flag.BoolVar(&opt.yes, "yes", false, "with -delete-save: don't ask for confirmation")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Cargo Earth installer %s\n\nRun without options to choose from a menu, or use options:\n\n", buildVersion)
		flag.PrintDefaults()
		name := "CargoEarthSetup.exe"
		if runtime.GOOS == "linux" {
			name = "./CargoEarthSetup-linux-x86_64"
		}
		fmt.Fprintf(os.Stderr, "\nExamples:\n  %[1]s\n  %[1]s -version 0.10.0\n  %[1]s -uninstall\n  %[1]s -delete-save\n  %[1]s -zip cargo_earth_career_0.10.0.zip -helper cargo_earth_helper.py\n", name)
	}
	flag.Parse()

	fmt.Printf("Cargo Earth installer %s\n", buildVersion)
	interactive := len(os.Args) == 1
	if interactive && !menu() {
		return
	}
	err := run()
	fmt.Println()
	if err != nil {
		fmt.Printf("  ERROR: %v\n", err)
	}
	if interactive && !opt.noPause {
		fmt.Print("\nPress Enter to close this window.")
		stdin.ReadString('\n')
	}
	if err != nil {
		os.Exit(1)
	}
}

// menu is shown when the installer is started without options (double-click).
func menu() bool {
	fmt.Println()
	fmt.Println("  1  Install or update Cargo Earth (mod and helper)")
	fmt.Println("  2  Install or update only the mod")
	fmt.Println("  3  Remove Cargo Earth (career saves are kept)")
	fmt.Println("  4  Delete the Cargo Earth career save (start a new career)")
	fmt.Println("  5  Close")
	fmt.Print("\nType a number and press Enter: ")
	line, _ := stdin.ReadString('\n')
	switch strings.TrimSpace(line) {
	case "1", "":
	case "2":
		opt.modOnly = true
	case "3":
		opt.uninstall = true
	case "4":
		opt.deleteSave = true
	default:
		return false
	}
	return true
}

func run() error {
	var err error
	local, err = installerDataDir()
	if err != nil {
		return err
	}
	if opt.deleteSave {
		user, err := findUserFolder()
		if err != nil {
			return err
		}
		say("BeamNG user folder: %s", user)
		return deleteSave(user)
	}
	if opt.modOnly && opt.helperOnly {
		return errors.New("use -mod-only or -helper-only, not both")
	}
	doMod, doHelper := !opt.helperOnly, !opt.modOnly
	var user string
	if doMod {
		var err error
		if user, err = findUserFolder(); err != nil {
			return err
		}
		say("BeamNG user folder: %s", user)
	}

	if opt.uninstall {
		if doMod {
			removeMod(user)
		}
		if doHelper {
			if err := removeHelper(); err != nil {
				return err
			}
		}
		fmt.Println()
		if opt.dryRun {
			fmt.Println("Dry run finished. Nothing was changed.")
		} else {
			fmt.Println("Done. Cargo Earth was removed.")
		}
		return nil
	}

	var rel *release
	tag := "local"
	if opt.version != "" {
		tag = "v" + strings.TrimPrefix(opt.version, "v")
	}
	if (doMod && opt.zipPath == "") || (doHelper && opt.helperPath == "") {
		step("Download")
		var err error
		if rel, err = getRelease(); err != nil {
			return err
		}
		tag = rel.Tag
		say("Release %s", tag)
	}
	tmp, err := os.MkdirTemp("", "cargo-earth-setup-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	if doMod {
		zipFile := opt.zipPath
		if zipFile == "" {
			if zipFile, err = getAsset(rel, `^cargo_earth.*\.zip$`, "mod ZIP", tmp); err != nil {
				return err
			}
		} else if zipFile, err = existing(zipFile); err != nil {
			return err
		}
		if err := installMod(zipFile, user); err != nil {
			return err
		}
	}
	if doHelper {
		if user == "" {
			user, _ = findUserFolder() // helper-only installs can still synchronize an existing mod configuration
		}
		py := opt.helperPath
		if py == "" {
			if py, err = getAsset(rel, `^cargo_earth_helper.*\.py$`, "helper", tmp); err != nil {
				return err
			}
		} else if py, err = existing(py); err != nil {
			return err
		}
		if err := installHelper(py, tag, user); err != nil {
			return err
		}
	}

	fmt.Println()
	if opt.dryRun {
		fmt.Println("Dry run finished. Nothing was changed.")
		return nil
	}
	fmt.Println("Done.")
	if doMod {
		say(`Start BeamNG.drive, load a BeamNG.Earth world and add the "Cargo Earth: Phone" UI app.`)
	}
	if doHelper {
		say("The helper starts with BeamNG.Earth. The mod needs it for places to work at.")
	}
	return nil
}

func existing(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(abs); err != nil {
		return "", fmt.Errorf("%s was not found", p)
	}
	return abs, nil
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// ------------------------------------------------------------------ the BeamNG user folder

var versionDir = regexp.MustCompile(`^\d+\.\d+$`)

func findUserFolder() (string, error) {
	if opt.userFolder != "" {
		if !isDir(opt.userFolder) {
			return "", fmt.Errorf("the user folder %q does not exist", opt.userFolder)
		}
		return filepath.Abs(opt.userFolder)
	}
	if runtime.GOOS == "linux" {
		return findLinuxUserFolder()
	}
	var candidates []string
	if current := filepath.Join(local, "BeamNG", "BeamNG.drive", "current"); isDir(current) {
		candidates = append(candidates, current)
	}
	// older game versions: %LOCALAPPDATA%\BeamNG.drive\<version>, newest first
	for _, root := range []string{filepath.Join(local, "BeamNG", "BeamNG.drive"), filepath.Join(local, "BeamNG.drive")} {
		entries, _ := os.ReadDir(root)
		var versions []string
		for _, e := range entries {
			if e.IsDir() && versionDir.MatchString(e.Name()) {
				versions = append(versions, e.Name())
			}
		}
		sort.Slice(versions, func(i, j int) bool { return versionLess(versions[j], versions[i]) })
		for _, v := range versions {
			candidates = append(candidates, filepath.Join(root, v))
		}
	}
	if len(candidates) == 0 {
		return "", errors.New("the BeamNG user folder was not found. Open the BeamNG launcher > Manage User Folder > Open, " +
			`then run this again from a command prompt with -user-folder "<that folder>"`)
	}
	return candidates[0], nil
}

func versionLess(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) && i < len(pb); i++ {
		x, _ := strconv.Atoi(pa[i])
		y, _ := strconv.Atoi(pb[i])
		if x != y {
			return x < y
		}
	}
	return len(pa) < len(pb)
}

// ------------------------------------------------------------------ downloads

type asset struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	URL  string `json:"browser_download_url"`
}

type release struct {
	Tag    string  `json:"tag_name"`
	Assets []asset `json:"assets"`
}

var client = &http.Client{Timeout: 10 * time.Minute}

func get(url string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	return client.Do(req)
}

func getRelease() (*release, error) {
	url := "https://api.github.com/repos/" + repo + "/releases/latest"
	if opt.version != "" {
		url = "https://api.github.com/repos/" + repo + "/releases/tags/v" + strings.TrimPrefix(opt.version, "v")
	}
	fail := func(why string) error {
		return fmt.Errorf("could not find a Cargo Earth release at %s (%s). Check the version, or use -zip / -helper", url, why)
	}
	resp, err := get(url)
	if err != nil {
		return nil, fail(err.Error())
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fail(resp.Status)
	}
	var rel release
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, fail(err.Error())
	}
	return &rel, nil
}

func getAsset(rel *release, pattern, what, dir string) (string, error) {
	re := regexp.MustCompile(pattern)
	for _, a := range rel.Assets {
		if !re.MatchString(a.Name) {
			continue
		}
		target := filepath.Join(dir, a.Name)
		say("Downloading %s (%.1f MB)", a.Name, float64(a.Size)/1048576)
		resp, err := get(a.URL)
		if err != nil {
			return "", fmt.Errorf("download of %s failed: %v", a.Name, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("download of %s failed: %s", a.Name, resp.Status)
		}
		f, err := os.Create(target)
		if err != nil {
			return "", err
		}
		if _, err := io.Copy(f, resp.Body); err != nil {
			f.Close()
			return "", fmt.Errorf("download of %s failed: %v", a.Name, err)
		}
		return target, f.Close()
	}
	return "", fmt.Errorf("release %s has no %s file", rel.Tag, what)
}

// ------------------------------------------------------------------ the mod

func checkModZip(path string) error {
	r, err := zip.OpenReader(path)
	if err != nil {
		return fmt.Errorf("%s is not a readable ZIP file. Download it again", path)
	}
	defer r.Close()
	for _, f := range r.File {
		if strings.ReplaceAll(f.Name, `\`, "/") == modMarker {
			return nil
		}
	}
	return fmt.Errorf("%s is not a Cargo Earth mod ZIP (%s is missing at its root)", path, modMarker)
}

var modZip = regexp.MustCompile(`(?i)^cargo_earth.*\.zip$`)

// modZips lists every Cargo Earth ZIP under the mods folder, including subfolders such as mods\repo.
func modZips(mods string) []string {
	var found []string
	filepath.WalkDir(mods, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && modZip.MatchString(d.Name()) {
			found = append(found, p)
		}
		return nil
	})
	return found
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	if err := copyFile(src, dst); err != nil {
		return err
	}
	return os.Remove(src)
}

func installMod(zipFile, user string) error {
	step("Mod")
	if err := checkModZip(zipFile); err != nil {
		return err
	}
	mods := filepath.Join(user, "mods")
	name := filepath.Base(zipFile)
	if !modZip.MatchString(name) {
		name = "cargo_earth_career.zip"
	}
	target := filepath.Join(mods, name)
	if err := doIt("create "+mods, func() error { return os.MkdirAll(mods, 0o755) }); err != nil {
		return err
	}
	backup := filepath.Join(user, "cargo_earth_old_mods")
	for _, old := range modZips(mods) {
		if old == target || (runtime.GOOS == "windows" && strings.EqualFold(old, target)) {
			continue
		}
		dst := filepath.Join(backup, filepath.Base(old))
		if err := doIt("move "+old+" to "+backup, func() error {
			if err := os.MkdirAll(backup, 0o755); err != nil {
				return err
			}
			return moveFile(old, dst)
		}); err != nil {
			return fmt.Errorf("could not move the older %s out of mods: %v. Close BeamNG.drive and try again", filepath.Base(old), err)
		}
		say("Moved the older %s out of mods (kept in cargo_earth_old_mods).", filepath.Base(old))
	}
	if unpacked := filepath.Join(mods, "unpacked", "cargo_earth"); isDir(unpacked) {
		warn("An unpacked copy exists in %s. Remove it, or it loads together with the ZIP.", unpacked)
	}
	if err := doIt("copy "+name+" to "+mods, func() error { return copyFile(zipFile, target) }); err != nil {
		return fmt.Errorf("could not copy the mod: %v. Close BeamNG.drive and try again", err)
	}
	say("Installed %s in %s", name, mods)
	return nil
}

func removeMod(user string) {
	step("Mod")
	found := modZips(filepath.Join(user, "mods"))
	if len(found) == 0 {
		say("No Cargo Earth ZIP in mods.")
	}
	for _, f := range found {
		if err := doIt("delete "+f, func() error { return os.Remove(f) }); err != nil {
			warn("Could not delete %s: %v", f, err)
			continue
		}
		say("Removed %s", filepath.Base(f))
	}
	say("Career saves stay in %s.", filepath.Join(user, "settings", "cargoEarth"))
}

// ------------------------------------------------------------------ the helper

type python struct {
	exe     string
	args    []string
	version string
}

func findPython() *python {
	commands := [][]string{{"py", "-3"}, {"python"}, {"python3"}}
	if runtime.GOOS == "linux" {
		commands = [][]string{{"python3"}, {"python"}}
	}
	for _, cmd := range commands {
		exe, err := exec.LookPath(cmd[0])
		if err != nil {
			continue
		}
		args := append(append([]string{}, cmd[1:]...), "-c", `import sys; print("%d.%d" % sys.version_info[:2])`)
		out, err := exec.Command(exe, args...).Output()
		if err != nil {
			continue // e.g. the Microsoft Store "python" alias when Python is not installed
		}
		v := strings.TrimSpace(string(out))
		if !versionLess(v, "3.9") && versionDir.MatchString(v) {
			return &python{exe: exe, args: cmd[1:], version: v}
		}
	}
	return nil
}

func addonsFile() string { return filepath.Join(earthDataDir(), "addons", "local.json") }
func helperDir() string  { return filepath.Join(local, "CargoEarth", "helper") }

// readAddons keeps every field of the file and of other add-ons as they are.
func readAddons() (map[string]any, []any, error) {
	data := map[string]any{"format": 1}
	raw, err := os.ReadFile(addonsFile())
	if err == nil && len(strings.TrimSpace(strings.TrimPrefix(string(raw), "\uFEFF"))) > 0 {
		if err := json.Unmarshal([]byte(strings.TrimPrefix(string(raw), "\uFEFF")), &data); err != nil || data == nil {
			return nil, nil, fmt.Errorf("%s is not valid JSON. Fix or rename it, then run again", addonsFile())
		}
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	list, _ := data["addons"].([]any)
	return data, list, nil
}

func withoutHelper(list []any) []any {
	out := []any{}
	for _, a := range list {
		if m, ok := a.(map[string]any); ok && m["id"] == addonID {
			continue
		}
		if a != nil {
			out = append(out, a)
		}
	}
	return out
}

func writeAddons(data map[string]any) error {
	file := addonsFile()
	return doIt("write "+file, func() error {
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			return err
		}
		if _, err := os.Stat(file); err == nil {
			if err := copyFile(file, file+".bak"); err != nil {
				return err
			}
		}
		out, err := json.MarshalIndent(data, "", "  ")
		if err != nil {
			return err
		}
		tmp := file + ".part"
		if err := os.WriteFile(tmp, append(out, '\n'), 0o644); err != nil {
			return err
		}
		return os.Rename(tmp, file)
	})
}

func installHelper(py, tag, user string) error {
	step("Helper")
	network, err := planHelperNetwork(user)
	if err != nil {
		return err
	}
	port := network.port
	dir := helperDir()
	name := filepath.Base(py)
	target := filepath.Join(dir, name)
	if err := doIt("copy "+name+" to "+dir, func() error {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		old, _ := filepath.Glob(filepath.Join(dir, "cargo_earth_helper*.py"))
		for _, f := range old {
			if filepath.Base(f) != name {
				os.Remove(f)
			}
		}
		return copyFile(py, target)
	}); err != nil {
		return fmt.Errorf("could not copy the helper: %v", err)
	}
	say("Helper: %s", target)

	if runtime.GOOS == "linux" {
		if err := installLinuxPython(target, port); err != nil {
			return err
		}
	} else if p := findPython(); p == nil {
		warn("Python 3.9 or newer was not found. Install it (for example: winget install Python.Python.3.12), then run this again.")
	} else {
		say("Python %s: %s", p.version, p.exe)
		if !opt.skipPython {
			doIt("pip install duckdb fsspec", func() error {
				args := append(append([]string{}, p.args...), "-m", "pip", "install", "--user", "--upgrade",
					"--disable-pip-version-check", "duckdb", "fsspec")
				cmd := exec.Command(p.exe, args...)
				cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
				if err := cmd.Run(); err != nil {
					warn("pip could not install duckdb and fsspec. Run: python -m pip install duckdb fsspec")
				}
				return nil
			})
		}
		launcher := filepath.Join(dir, "start_helper.cmd")
		parts := []string{`"` + p.exe + `"`}
		parts = append(parts, p.args...)
		parts = append(parts, `"`+target+`"`, "--port", strconv.Itoa(port))
		script := "@echo off\r\ntitle Cargo Earth helper\r\n" + strings.Join(parts, " ") + "\r\npause\r\n"
		if err := doIt("write "+launcher, func() error { return os.WriteFile(launcher, []byte(script), 0o644) }); err != nil {
			return err
		}
		say("To run it by hand: %s", launcher)
	}

	// BeamNG.Earth starts companion add-ons listed in local.json
	data, list, err := readAddons()
	if err != nil {
		return err
	}
	if err := network.save(); err != nil {
		return fmt.Errorf("could not synchronize the helper port: %w", err)
	}
	entry := map[string]any{
		"id": addonID, "name": "Cargo Earth helper", "author": "themazzy", "repo": repo, "kind": "companion",
		"summary": "Restaurants, shops, workplaces and customer addresses anywhere in the world for the Cargo Earth mod.",
		"licence": "MIT", "asset": `^cargo_earth_helper.*\.py$`,
		"local":   map[string]any{"file": target, "tag": tag},
		"options": helperPortOption(port),
		"run":     map[string]any{"args": []any{}, "port": port, "page": "http://127.0.0.1:{port}/"},
	}
	data["addons"] = append(withoutHelper(list), entry)
	if err := writeAddons(data); err != nil {
		return fmt.Errorf("could not register the helper with BeamNG.Earth: %v", err)
	}
	say("Registered with BeamNG.Earth in %s (other add-ons kept, old file saved as local.json.bak).", addonsFile())
	say("Cargo Earth uses port %d; EarthRadio keeps port %d. Restart BeamNG.Earth to stop any old helper process.", port, legacyHelperPort)
	if user == "" && port != helperPort {
		warn("The BeamNG user folder was not found. Set helperPort to %d in settings/cargoEarth/config.json, or rerun with -user-folder.", port)
	}
	if err := updateEarthCopy(target, tag); err != nil {
		warn("BeamNG.Earth's own copy of the helper could not be updated (%v). Open BeamNG.Earth's Add-ons page and press Update on Cargo Earth helper.", err)
	}
	if !isDir(earthDataDir()) {
		warn("BeamNG.Earth's app folder was not found. Install BeamNG.Earth first, or run the helper with the manual launcher shown above.")
	}
	return nil
}

// earthCopyDir is where BeamNG.Earth keeps the helper it installed from the local list and runs (addonrun.py:
// <data>/addons/<id>/ with installed.json naming the file). Earth only replaces that copy when Update is pressed on
// its Add-ons page, so a new installer run would leave the old helper running.
func earthCopyDir() string { return filepath.Join(earthDataDir(), "addons", addonID) }

// updateEarthCopy puts the new helper into BeamNG.Earth's installed copy (addonrun.Runner reads only installed.json
// and the file it names; Earth's own consent dialog guards its Install button, and running this installer is the
// player's agreement): the file beside the old one, installed.json pointing at it, older helper files removed. Earth
// starts companions whose installed.json says autostart: true, and its own Install never writes that key, so the
// helper used to wait for the player to find "Start with BeamNG.Earth" (players complained, 2026-11-16). A missing key
// is set to true; a player's own false (they turned it off on the Add-ons page) is kept.
func updateEarthCopy(target, tag string) error {
	dir := earthCopyDir()
	statePath := filepath.Join(dir, "installed.json")
	state := map[string]any{}
	raw, err := os.ReadFile(statePath)
	if err == nil {
		if err := json.Unmarshal(raw, &state); err != nil {
			return fmt.Errorf("installed.json: %v", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_, chose := state["autostart"]
	name := filepath.Base(target)
	if state["file"] == name && state["tag"] == tag && chose && fileExists(filepath.Join(dir, name)) {
		return nil
	}
	if !chose {
		state["autostart"] = true
	}
	data, err := os.ReadFile(target)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	return doIt("update BeamNG.Earth's copy in "+dir, func() error {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		if err := copyFile(target, filepath.Join(dir, name)); err != nil {
			return err
		}
		state["file"], state["tag"], state["sha256"], state["local"] = name, tag, hex.EncodeToString(sum[:]), true
		out, err := json.Marshal(state)
		if err != nil {
			return err
		}
		if err := os.WriteFile(statePath+".tmp", out, 0o644); err != nil {
			return err
		}
		if err := os.Rename(statePath+".tmp", statePath); err != nil {
			return err
		}
		old, _ := filepath.Glob(filepath.Join(dir, "cargo_earth_helper*.py"))
		for _, f := range old {
			if filepath.Base(f) != name {
				os.Remove(f)
			}
		}
		say("BeamNG.Earth's copy now runs %s (restart BeamNG.Earth if an old helper is still running).", name)
		if state["autostart"] == true {
			say("BeamNG.Earth starts the helper whenever it starts (Add-ons page: Start with BeamNG.Earth).")
		} else {
			say("You set the helper to start only by hand: press Start on BeamNG.Earth's Add-ons page, or turn on Start with BeamNG.Earth there.")
		}
		return nil
	})
}

func removeHelper() error {
	step("Helper")
	dir := helperDir()
	if isDir(dir) {
		if err := doIt("delete "+dir, func() error { return os.RemoveAll(dir) }); err != nil {
			return fmt.Errorf("could not delete %s: %v. Close the helper window and try again", dir, err)
		}
		say("Removed %s (its download cache too).", dir)
	} else {
		say("No helper installed.")
	}
	if _, err := os.Stat(addonsFile()); err != nil {
		return nil
	}
	data, list, err := readAddons()
	if err != nil {
		return err
	}
	kept := withoutHelper(list)
	if len(kept) != len(list) {
		data["addons"] = kept
		if err := writeAddons(data); err != nil {
			return err
		}
		say("Removed the helper from BeamNG.Earth's add-on list.")
	}
	return nil
}

// ------------------------------------------------------------------ the career save

// saveFiles lists every career save (career.json, career-2.json, ...), the copies the mod keeps beside them
// (.pending, .backup1, .backup2, .legacy), the list of careers (saves.json) and the free-play save.
// config.json is a setting, not progress, and stays.
func saveFiles(user string) []string {
	dir := filepath.Join(user, "settings", "cargoEarth")
	var found []string
	for _, pattern := range []string{"career.json*", "career-*.json*", "saves.json", "freeplay.json*"} {
		matches, _ := filepath.Glob(filepath.Join(dir, pattern))
		for _, p := range matches {
			if fileExists(p) {
				found = append(found, p)
			}
		}
	}
	return found
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// gameRunning reports whether BeamNG.drive is open; it would write the save again when it closes.
func gameRunning() bool {
	if runtime.GOOS == "linux" {
		return linuxGameRunning()
	}
	if runtime.GOOS != "windows" {
		return false
	}
	out, err := exec.Command("tasklist", "/NH", "/FO", "CSV").Output()
	return err == nil && strings.Contains(strings.ToLower(string(out)), "beamng.drive")
}

func deleteSave(user string) error {
	step("Career save")
	files := saveFiles(user)
	if len(files) == 0 {
		say("No Cargo Earth career save found in %s.", filepath.Join(user, "settings", "cargoEarth"))
		return nil
	}
	if gameRunning() {
		return errors.New("BeamNG.drive is running. Close the game first, or it saves the career again when it exits")
	}
	for _, f := range files {
		say("%s", f)
	}
	say("This deletes your whole Cargo Earth career: money, cars, home, reputation and progress.")
	say("It cannot be undone. Settings (config.json) are kept.")
	if !opt.yes && !opt.dryRun {
		fmt.Print("\n  Type DELETE and press Enter to confirm: ")
		line, _ := stdin.ReadString('\n')
		if strings.TrimSpace(line) != "DELETE" {
			say("Nothing was deleted.")
			return nil
		}
	}
	for _, f := range files {
		if err := doIt("delete "+f, func() error { return os.Remove(f) }); err != nil {
			return fmt.Errorf("could not delete %s: %v", f, err)
		}
	}
	fmt.Println()
	if opt.dryRun {
		fmt.Println("Dry run finished. Nothing was changed.")
	} else {
		fmt.Println("Done. The career save was deleted. The next time you open the phone, Cargo Earth starts a new career.")
	}
	return nil
}
