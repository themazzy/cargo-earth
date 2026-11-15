package main

import (
	"archive/zip"
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
