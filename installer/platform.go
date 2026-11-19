package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

func installerDataDir() (string, error) {
	if runtime.GOOS == "windows" {
		if p := os.Getenv("LOCALAPPDATA"); p != "" {
			return p, nil
		}
		return "", errors.New("LOCALAPPDATA is not set")
	}
	if runtime.GOOS != "linux" {
		return "", errors.New("this installer supports Windows and Linux")
	}
	if p := os.Getenv("XDG_DATA_HOME"); filepath.IsAbs(p) {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share"), nil
}

func earthDataDir() string {
	if runtime.GOOS == "linux" {
		// Match BeamNG.Earth's apppaths.data_dir(), which does not use XDG_CACHE_HOME.
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".cache", "beamng-earth")
	}
	return filepath.Join(local, "beamng-earth")
}

func findLinuxUserFolder() (string, error) {
	// Prefer the active profile reported by the game to BeamNG.Earth.
	var settings struct {
		User string `json:"gameUserDir"`
	}
	if raw, err := os.ReadFile(filepath.Join(earthDataDir(), "app.json")); err == nil {
		if json.Unmarshal(raw, &settings) == nil && filepath.IsAbs(settings.User) && isDir(settings.User) {
			return settings.User, nil
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	roots := []string{
		local, filepath.Join(home, ".local", "share"),
		filepath.Join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share"),
		filepath.Join(home, ".var", "app", "com.valvesoftware.Steam", "data"),
		filepath.Join(home, "snap", "steam", "common", ".local", "share"),
	}
	var candidates []string
	seen := map[string]bool{}
	add := func(p string) {
		if !isDir(p) {
			return
		}
		real, err := filepath.EvalSymlinks(p)
		if err == nil && !seen[real] {
			seen[real] = true
			candidates = append(candidates, p)
		}
	}
	for _, root := range roots {
		for _, base := range []string{filepath.Join(root, "BeamNG", "BeamNG.drive"), filepath.Join(root, "BeamNG.drive")} {
			current := filepath.Join(base, "current")
			if isDir(current) {
				add(current)
				continue
			}
			entries, _ := os.ReadDir(base)
			var versions []string
			for _, e := range entries {
				if e.IsDir() && versionDir.MatchString(e.Name()) {
					versions = append(versions, e.Name())
				}
			}
			sort.Slice(versions, func(i, j int) bool { return versionLess(versions[j], versions[i]) })
			if len(versions) > 0 {
				add(filepath.Join(base, versions[0]))
			}
		}
	}
	if len(candidates) == 1 {
		return candidates[0], nil
	}
	if len(candidates) > 1 {
		return "", fmt.Errorf("multiple BeamNG profiles found:\n  %s\nchoose the active one with -user-folder \"<path>\"", strings.Join(candidates, "\n  "))
	}
	return "", errors.New("BeamNG user folder not found. Start the game once, then use -user-folder \"<active profile path>\" (also required for custom or Proton profiles)")
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

func installLinuxPython(target string, port int) error {
	p := findPython()
	if p == nil {
		return errors.New("Python 3.9 or newer is required. Install python3 and its venv package, then run this installer again")
	}
	if !opt.skipPython {
		// A private environment avoids PEP 668 and leaves the system Python untouched.
		venv := filepath.Join(helperDir(), "venv")
		if err := doIt("create Python environment in "+venv, func() error {
			cmd := exec.Command(p.exe, "-m", "venv", venv)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("could not create Python environment: install your distribution's python3-venv package and retry: %w", err)
			}
			return nil
		}); err != nil {
			return err
		}
		p = &python{exe: filepath.Join(venv, "bin", "python")}
		if err := doIt("install duckdb and fsspec in "+venv, func() error {
			cmd := exec.Command(p.exe, "-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "duckdb", "fsspec")
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("helper dependency installation failed: %w", err)
			}
			return nil
		}); err != nil {
			return err
		}
	}
	launcher := filepath.Join(helperDir(), "start_helper.sh")
	script := "#!/bin/sh\nexec " + shellQuote(p.exe) + " " + shellQuote(target) + " --port " + strconv.Itoa(port) + " \"$@\"\n"
	if err := doIt("write "+launcher, func() error { return os.WriteFile(launcher, []byte(script), 0o755) }); err != nil {
		return err
	}
	say("To run the helper by hand: %s", launcher)
	return nil
}

func linuxGameRunning() bool {
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		// comm can be truncated to 15 characters; cmdline includes the full executable.
		for _, name := range []string{"comm", "cmdline"} {
			raw, _ := os.ReadFile(filepath.Join("/proc", e.Name(), name))
			if isBeamNGProcess(string(raw)) {
				return true
			}
		}
	}
	return false
}

func isBeamNGProcess(raw string) bool {
	// Only the process name, never its arguments: -user-folder often contains BeamNG.drive.
	name := strings.SplitN(raw, "\x00", 2)[0]
	return strings.HasPrefix(strings.ToLower(filepath.Base(strings.TrimSpace(name))), "beamng.drive")
}
