package main

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func testModZip(t *testing.T, path string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(f)
	w, err := z.Create(modMarker)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("return {}")); err != nil {
		t.Fatal(err)
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func resetOptions(t *testing.T) {
	t.Helper()
	previous, previousLocal := opt, local
	opt = options{}
	t.Cleanup(func() { opt, local = previous, previousLocal })
}

func TestModUpdateAndRemovalPreserveSave(t *testing.T) {
	resetOptions(t)
	root := t.TempDir()
	user := filepath.Join(root, "profile")
	old := filepath.Join(user, "mods", "repo", "cargo_earth_career_old.zip")
	save := filepath.Join(user, "settings", "cargoEarth", "career.json")
	unrelated := filepath.Join(user, "mods", "another_mod.zip")
	writeTestFile(t, old, "old mod")
	writeTestFile(t, save, `{"money":123}`)
	writeTestFile(t, unrelated, "other mod")
	archive := filepath.Join(root, "cargo_earth_career_new.zip")
	testModZip(t, archive)
	if err := installMod(archive, user); err != nil {
		t.Fatal(err)
	}
	if fileExists(old) || !fileExists(filepath.Join(user, "cargo_earth_old_mods", filepath.Base(old))) {
		t.Fatal("old mod was not archived")
	}
	// Installing again replaces the same file successfully on Windows as well.
	if err := installMod(archive, user); err != nil {
		t.Fatal(err)
	}
	removeMod(user)
	if len(modZips(filepath.Join(user, "mods"))) != 0 {
		t.Fatal("Cargo Earth ZIP remains after uninstall")
	}
	if raw, _ := os.ReadFile(save); string(raw) != `{"money":123}` {
		t.Fatal("career save changed")
	}
	if !fileExists(unrelated) {
		t.Fatal("unrelated mod removed")
	}
}

func TestEarthCopyFollowsNewHelper(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	local = tmp
	dir := earthCopyDir()
	readState := func() map[string]any {
		raw, err := os.ReadFile(filepath.Join(dir, "installed.json"))
		if err != nil {
			t.Fatal(err)
		}
		state := map[string]any{}
		if err := json.Unmarshal(raw, &state); err != nil {
			t.Fatal(err)
		}
		return state
	}
	// Earth has not installed the helper: the installer does, set to start with BeamNG.Earth
	first := filepath.Join(tmp, "CargoEarth", "helper", "cargo_earth_helper_0.9.0.py")
	writeTestFile(t, first, "first")
	if err := updateEarthCopy(first, "v0.9.0"); err != nil {
		t.Fatal(err)
	}
	if st := readState(); st["file"] != "cargo_earth_helper_0.9.0.py" || st["autostart"] != true || st["local"] != true {
		t.Fatalf("fresh copy: %v", st)
	}
	// the player turned autostart off on the Add-ons page: kept
	writeTestFile(t, filepath.Join(dir, "installed.json"),
		`{"file": "cargo_earth_helper_0.9.0.py", "tag": "v0.9.0", "sha256": "x", "local": true, "autostart": false}`)
	if err := updateEarthCopy(first, "v0.9.1"); err != nil {
		t.Fatal(err)
	}
	if st := readState(); st["autostart"] != false || st["tag"] != "v0.9.1" {
		t.Fatalf("player's choice: %v", st)
	}
	// Earth's own Install writes no autostart key: turned on, even when the file is already current
	writeTestFile(t, filepath.Join(dir, "installed.json"),
		`{"file": "cargo_earth_helper_0.9.0.py", "tag": "v0.9.1", "sha256": "x", "local": true}`)
	if err := updateEarthCopy(first, "v0.9.1"); err != nil {
		t.Fatal(err)
	}
	if st := readState(); st["autostart"] != true {
		t.Fatalf("Earth's install: %v", st)
	}
	writeTestFile(t, filepath.Join(dir, "cargo_earth_helper_0.10.0.py"), "old")
	writeTestFile(t, filepath.Join(dir, "installed.json"),
		`{"file": "cargo_earth_helper_0.10.0.py", "tag": "v0.10.0", "sha256": "x", "local": true, "autostart": true}`)
	target := filepath.Join(tmp, "CargoEarth", "helper", "cargo_earth_helper_0.10.1.py")
	writeTestFile(t, target, "new")
	if err := updateEarthCopy(target, "v0.10.1"); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "installed.json"))
	if err != nil {
		t.Fatal(err)
	}
	state := map[string]any{}
	if err := json.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	if state["file"] != "cargo_earth_helper_0.10.1.py" || state["tag"] != "v0.10.1" || state["autostart"] != true ||
		state["sha256"] != "11507a0e2f5e69d5dfa40a62a1bd7b6ee57e6bcd85c67c9b8431b36fff21c437" {
		t.Fatalf("installed.json: %v", state)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "cargo_earth_helper_0.10.1.py")); string(got) != "new" {
		t.Fatalf("copy: %q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "cargo_earth_helper_0.10.0.py")); !os.IsNotExist(err) {
		t.Fatal("the old helper should be removed")
	}
}
