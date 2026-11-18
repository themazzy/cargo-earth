package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func networkTestRoot(t *testing.T) string {
	t.Helper()
	resetOptions(t)
	root := t.TempDir()
	t.Setenv("HOME", root)
	local = root
	return filepath.Join(root, "profile")
}

func TestHelperPortMigrationAndCustomChoices(t *testing.T) {
	for _, tt := range []struct {
		name, config, options, run string
		want                       int
	}{
		{"fresh", `{}`, `{}`, `{}`, 47821},
		{"legacy", `{"helperPort":47820,"helper":false}`, `{"port":47820,"keep":true}`, `{"port":47820}`, 47821},
		{"custom client", `{"helperPort":53100}`, `{"port":47820}`, `{"port":47820}`, 53100},
		{"custom option", `{"helperPort":47820}`, `{"port":53101}`, `{"port":47820}`, 53101},
		{"custom run", `{}`, `{}`, `{"port":53102}`, 53102},
		{"custom args", `{}`, `{}`, `{"port":47820,"args":["--port","53103"]}`, 53103},
		{"custom equals arg", `{}`, `{}`, `{"args":["--port=53104"]}`, 53104},
		{"invalid", `{"helperPort":99999}`, `{"port":12}`, `{"port":47820}`, 47821},
	} {
		t.Run(tt.name, func(t *testing.T) {
			user := networkTestRoot(t)
			cfgPath := filepath.Join(user, "settings", "cargoEarth", "config.json")
			optsPath := filepath.Join(earthCopyDir(), "options.json")
			writeTestFile(t, cfgPath, tt.config)
			writeTestFile(t, optsPath, tt.options)
			other := `{"id":"earthradio","run":{"port":47820},"keep":"untouched"}`
			localJSON := `{"format":1,"custom":true,"addons":[` + other + `,{"id":"cargo-earth-helper","run":` + tt.run + `}]}`
			writeTestFile(t, addonsFile(), localJSON)
			plan, err := planHelperNetwork(user)
			if err != nil || plan.port != tt.want {
				t.Fatalf("plan %v, %v; want port %d", plan, err, tt.want)
			}
			if err := plan.save(); err != nil {
				t.Fatal(err)
			}
			cfg, _ := readSettings(cfgPath)
			opts, _ := readSettings(optsPath)
			if portNumber(opts["port"]) != tt.want || (tt.config != `{}` || tt.want != helperPort) && portNumber(cfg["helperPort"]) != tt.want {
				t.Fatalf("ports not synchronized: %v, %v", cfg, opts)
			}
			if raw, _ := os.ReadFile(addonsFile()); string(raw) != localJSON {
				t.Fatal("planning changed an add-on entry")
			}
			if tt.name == "legacy" {
				if cfg["helper"] != false || opts["keep"] != true {
					t.Fatal("unrelated settings changed")
				}
				if raw, _ := os.ReadFile(cfgPath + ".bak"); string(raw) != tt.config {
					t.Fatal("config backup missing")
				}
			}
		})
	}
}

func TestHelperNetworkDoesNotOverwriteInvalidJSON(t *testing.T) {
	user := networkTestRoot(t)
	file := filepath.Join(user, "settings", "cargoEarth", "config.json")
	for _, raw := range []string{"{broken", "null", "[]"} {
		writeTestFile(t, file, raw)
		if _, err := planHelperNetwork(user); err == nil {
			t.Fatalf("accepted corrupt config: %s", raw)
		}
		if got, _ := os.ReadFile(file); string(got) != raw {
			t.Fatal("corrupt config overwritten")
		}
	}
}

func TestHelperNetworkKeepsCustomAddonOptionDefault(t *testing.T) {
	user := networkTestRoot(t)
	writeTestFile(t, addonsFile(), `{"addons":[{"id":"cargo-earth-helper","options":[{"key":"port","default":53105,"arg":"--port"}],"run":{"port":47820}}]}`)
	plan, err := planHelperNetwork(user)
	if err != nil || plan.port != 53105 {
		t.Fatalf("custom add-on option lost: %v, %v", plan, err)
	}
}

func TestHelperNetworkDryRun(t *testing.T) {
	user := networkTestRoot(t)
	file := filepath.Join(user, "settings", "cargoEarth", "config.json")
	writeTestFile(t, file, `{"helperPort":47820}`)
	opt.dryRun = true
	plan, err := planHelperNetwork(user)
	if err != nil {
		t.Fatal(err)
	}
	if err := plan.save(); err != nil {
		t.Fatal(err)
	}
	if raw, _ := os.ReadFile(file); string(raw) != `{"helperPort":47820}` {
		t.Fatal("dry run changed config")
	}
	if fileExists(plan.optionsPath) {
		t.Fatal("dry run wrote add-on options")
	}
}

func TestHelperInstallSynchronizesLaunchersAndAddon(t *testing.T) {
	user := networkTestRoot(t)
	opt.skipPython = true
	writeTestFile(t, filepath.Join(user, "settings", "cargoEarth", "config.json"), `{"helperPort":53123,"mode":"taxi"}`)
	writeTestFile(t, addonsFile(), `{"addons":[{"id":"earthradio","run":{"port":47820}}]}`)
	py := filepath.Join(local, "download", "cargo_earth_helper_test.py")
	writeTestFile(t, py, "print('helper')")
	if err := installHelper(py, "vtest", user); err != nil {
		t.Fatal(err)
	}
	_, list, err := readAddons()
	if err != nil || len(list) != 2 {
		t.Fatalf("add-ons: %v, %v", list, err)
	}
	other := list[0].(map[string]any)
	if other["id"] != "earthradio" || portNumber(other["run"].(map[string]any)["port"]) != 47820 {
		t.Fatal("EarthRadio changed")
	}
	entry := list[1].(map[string]any)
	run := entry["run"].(map[string]any)
	if portNumber(run["port"]) != 53123 || run["page"] != "http://127.0.0.1:{port}/" {
		t.Fatal("wrong launch metadata")
	}
	option := entry["options"].([]any)[0].(map[string]any)
	if portNumber(option["default"]) != 53123 || option["arg"] != "--port" {
		t.Fatal("automatic startup lacks a matching --port option")
	}
	launcher := "start_helper.cmd"
	if runtime.GOOS == "linux" {
		launcher = "start_helper.sh"
	}
	if raw, err := os.ReadFile(filepath.Join(helperDir(), launcher)); err == nil && !strings.Contains(string(raw), "--port 53123") {
		t.Fatal("manual launcher uses a different port")
	}
	state, _ := readSettings(filepath.Join(earthCopyDir(), "options.json"))
	if portNumber(state["port"]) != 53123 {
		t.Fatal("saved add-on port differs")
	}
	raw, _ := json.Marshal(entry)
	if strings.Contains(string(raw), `"port":47820`) {
		t.Fatal("legacy port remains in Cargo entry")
	}
}
