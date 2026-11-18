package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const legacyHelperPort = 47820 // EarthRadio's newline-JSON listener must keep this port to itself.

type helperNetwork struct {
	port        int
	configPath  string
	config      map[string]any
	optionsPath string
	options     map[string]any
}

func readSettings(path string) (map[string]any, error) {
	data := map[string]any{}
	if path == "" {
		return data, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return data, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(raw), "\uFEFF")), &data); err != nil || data == nil {
		return nil, fmt.Errorf("%s is not a JSON object; fix it before updating the helper", path)
	}
	return data, nil
}

func portNumber(value any) int {
	n, err := strconv.ParseFloat(fmt.Sprint(value), 64)
	if err != nil || n < 1024 || n > 65535 || n != float64(int(n)) {
		return 0
	}
	return int(n)
}

// Prefer an existing custom client port, then the helper's saved option/launch port. Retire 47820 everywhere.
// Reading every file first avoids overwriting a corrupt configuration or another add-on's entry.
func planHelperNetwork(user string) (*helperNetwork, error) {
	p := &helperNetwork{port: helperPort, optionsPath: filepath.Join(earthCopyDir(), "options.json")}
	if user != "" {
		p.configPath = filepath.Join(user, "settings", "cargoEarth", "config.json")
	}
	var err error
	if p.config, err = readSettings(p.configPath); err != nil {
		return nil, err
	}
	if p.options, err = readSettings(p.optionsPath); err != nil {
		return nil, err
	}
	_, list, err := readAddons()
	if err != nil {
		return nil, err
	}
	choices := []any{p.config["helperPort"], p.options["port"]}
	for _, item := range list {
		entry, _ := item.(map[string]any)
		if entry["id"] != addonID {
			continue
		}
		run, _ := entry["run"].(map[string]any)
		options, _ := entry["options"].([]any)
		for _, item := range options {
			option, _ := item.(map[string]any)
			if option["key"] == "port" {
				choices = append(choices, option["default"])
			}
		}
		args, _ := run["args"].([]any)
		var argPort any
		for i, arg := range args {
			if arg == "--port" && i+1 < len(args) {
				argPort = args[i+1]
			} else if s, ok := arg.(string); ok && strings.HasPrefix(s, "--port=") {
				argPort = strings.TrimPrefix(s, "--port=")
			}
		}
		choices = append(choices, argPort, run["port"])
	}
	for _, choice := range choices {
		if port := portNumber(choice); port != 0 && port != legacyHelperPort {
			p.port = port
			break
		}
	}
	return p, nil
}

func writeSettings(path string, data map[string]any) error {
	return doIt("write "+path, func() error {
		out, err := json.MarshalIndent(data, "", "  ")
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if fileExists(path) {
			if err := copyFile(path, path+".bak"); err != nil {
				return err
			}
		}
		if err := os.WriteFile(path+".tmp", append(out, '\n'), 0o644); err != nil {
			return err
		}
		return os.Rename(path+".tmp", path)
	})
}

func (p *helperNetwork) save() error {
	if portNumber(p.options["port"]) != p.port {
		p.options["port"] = p.port
		if err := writeSettings(p.optionsPath, p.options); err != nil {
			return err
		}
	}
	// Default installs need no config file. Custom ports and explicit legacy choices must match the launcher.
	if p.configPath != "" && portNumber(p.config["helperPort"]) != p.port && (p.port != helperPort || p.config["helperPort"] != nil) {
		p.config["helperPort"] = p.port
		if err := writeSettings(p.configPath, p.config); err != nil {
			return err
		}
	}
	return nil
}

func helperPortOption(port int) []any {
	return []any{map[string]any{"key": "port", "label": "Port", "type": "int", "default": port,
		"min": 1024, "max": 65535, "arg": "--port", "help": "Must match helperPort in Cargo Earth's config.json. Port 47820 is reserved for EarthRadio."}}
}
