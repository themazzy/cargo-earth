//go:build linux

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func linuxTestHome(t *testing.T) string {
	t.Helper()
	resetOptions(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_DATA_HOME", "")
	var err error
	local, err = installerDataDir()
	if err != nil {
		t.Fatal(err)
	}
	return home
}

func TestLinuxProfileDiscovery(t *testing.T) {
	for _, layout := range []string{
		".local/share/BeamNG/BeamNG.drive/current",
		".var/app/com.valvesoftware.Steam/.local/share/BeamNG/BeamNG.drive/current",
		".var/app/com.valvesoftware.Steam/data/BeamNG/BeamNG.drive/current",
		"snap/steam/common/.local/share/BeamNG/BeamNG.drive/current",
	} {
		t.Run(layout, func(t *testing.T) {
			home := linuxTestHome(t)
			want := filepath.Join(home, layout)
			if err := os.MkdirAll(want, 0o755); err != nil {
				t.Fatal(err)
			}
			got, err := findUserFolder()
			if err != nil || got != want {
				t.Fatalf("got %q, %v; want %q", got, err, want)
			}
		})
	}
}

func TestLinuxProfileChoice(t *testing.T) {
	home := linuxTestHome(t)
	a := filepath.Join(local, "BeamNG", "BeamNG.drive", "current")
	b := filepath.Join(home, ".var", "app", "com.valvesoftware.Steam", "data", "BeamNG", "BeamNG.drive", "current")
	for _, dir := range []string{a, b} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := findUserFolder(); err == nil {
		t.Fatal("ambiguous profiles silently accepted")
	}
	raw, _ := json.Marshal(map[string]string{"gameUserDir": b})
	writeTestFile(t, filepath.Join(earthDataDir(), "app.json"), string(raw))
	if got, err := findUserFolder(); err != nil || got != b {
		t.Fatalf("remembered profile: %q, %v", got, err)
	}
	opt.userFolder = a
	if got, err := findUserFolder(); err != nil || got != a {
		t.Fatalf("explicit profile: %q, %v", got, err)
	}
}

func TestLinuxXDGAndLegacyProfile(t *testing.T) {
	home := linuxTestHome(t)
	t.Setenv("XDG_DATA_HOME", filepath.Join(home, "custom-data"))
	var err error
	local, err = installerDataDir()
	if err != nil {
		t.Fatal(err)
	}
	for _, version := range []string{"0.9", "0.40"} {
		if err := os.MkdirAll(filepath.Join(local, "BeamNG.drive", version), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	want := filepath.Join(local, "BeamNG.drive", "0.40")
	if got, err := findUserFolder(); err != nil || got != want {
		t.Fatalf("legacy profile: %q, %v", got, err)
	}
	if addonsFile() != filepath.Join(home, ".cache", "beamng-earth", "addons", "local.json") {
		t.Fatal("wrong Earth add-on location")
	}
	t.Setenv("XDG_DATA_HOME", "relative-is-invalid")
	if got, _ := installerDataDir(); got != filepath.Join(home, ".local", "share") {
		t.Fatal("relative XDG path accepted")
	}
}

func TestLinuxHelperInstallAndUninstall(t *testing.T) {
	home := linuxTestHome(t)
	opt.skipPython = true // No network or package installation during this test.
	if findPython() == nil {
		t.Skip("Python 3.9+ is required for this integration test")
	}
	local = filepath.Join(home, "data's folder")
	other := `{"format":1,"custom":"keep","addons":[{"id":"other-addon","custom":42}]}`
	writeTestFile(t, addonsFile(), other)
	py := filepath.Join(home, "download's folder", "cargo_earth_helper_test.py")
	writeTestFile(t, py, "print('helper')\n")
	if err := installHelper(py, "vtest"); err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(helperDir(), "start_helper.sh")
	info, err := os.Stat(launcher)
	if err != nil || info.Mode()&0o111 == 0 {
		t.Fatal("helper launcher is not executable")
	}
	if out, err := exec.Command(launcher).Output(); err != nil || string(out) != "helper\n" {
		t.Fatalf("manual launcher failed with spaces and quotes in path: %q, %v", out, err)
	}
	data, list, err := readAddons()
	if err != nil || data["custom"] != "keep" || len(list) != 2 {
		t.Fatalf("other add-on metadata lost: %v", err)
	}
	if raw, _ := os.ReadFile(addonsFile() + ".bak"); string(raw) != other {
		t.Fatal("add-on backup missing")
	}
	// Update must not duplicate our entry.
	if err := installHelper(py, "vtest2"); err != nil {
		t.Fatal(err)
	}
	_, list, _ = readAddons()
	if len(list) != 2 {
		t.Fatal("duplicate helper registration")
	}
	if err := removeHelper(); err != nil {
		t.Fatal(err)
	}
	data, list, err = readAddons()
	if err != nil || data["custom"] != "keep" || len(list) != 1 {
		t.Fatal("uninstall changed other add-ons")
	}
	if isDir(helperDir()) {
		t.Fatal("helper directory remains after uninstall")
	}
}

func TestLinuxDryRunDoesNotWrite(t *testing.T) {
	linuxTestHome(t)
	opt.dryRun = true
	if err := installLinuxPython("/not-written/helper.py"); err != nil {
		t.Fatal(err)
	}
	if isDir(helperDir()) {
		t.Fatal("dry run wrote helper directory")
	}
}

func TestLinuxGameProcessDetection(t *testing.T) {
	for raw, want := range map[string]bool{
		"BeamNG.drive.x6\n": true,
		"/games/BeamNG/BinLinux/BeamNG.drive.x64\x00--flag":                               true,
		"./CargoEarthSetup-linux-x86_64\x00-user-folder\x00/home/me/BeamNG.drive/current": false,
	} {
		if got := isBeamNGProcess(raw); got != want {
			t.Fatalf("process %q: got %v, want %v", raw, got, want)
		}
	}
}
