// Package config reads server settings from flags and environment
// variables. Flags take precedence over the environment.
package config

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

// Config holds every server setting.
type Config struct {
	Addr             string
	DataDir          string
	PublicURL        string
	AnthropicAPIKey  string // environment only, so it never shows up in ps
	AIModel          string
	BlocklistRefresh time.Duration // 0 disables periodic downloads
}

// Load parses args (without the program name) using getenv for defaults.
func Load(args []string, getenv func(string) string, usage io.Writer) (Config, error) {
	env := func(key, fallback string) string {
		if v := getenv(key); v != "" {
			return v
		}
		return fallback
	}
	var refresh time.Duration
	if v := getenv("ARROW_BLOCKLIST_REFRESH"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("ARROW_BLOCKLIST_REFRESH: %w", err)
		}
		refresh = d
	}

	cfg := Config{AnthropicAPIKey: getenv("ANTHROPIC_API_KEY")}
	fs := flag.NewFlagSet("arrow-server", flag.ContinueOnError)
	fs.SetOutput(usage)
	fs.StringVar(&cfg.Addr, "addr", env("ARROW_ADDR", ":8787"), "listen address (env ARROW_ADDR)")
	fs.StringVar(&cfg.DataDir, "data-dir", env("ARROW_DATA_DIR", "./data"), "data directory (env ARROW_DATA_DIR)")
	fs.StringVar(&cfg.PublicURL, "public-url", env("ARROW_PUBLIC_URL", "http://localhost:8787"), "externally reachable base URL, used in share and block list links (env ARROW_PUBLIC_URL)")
	fs.StringVar(&cfg.AIModel, "ai-model", env("ARROW_AI_MODEL", "claude-opus-5-5"), "Claude model for AI features (env ARROW_AI_MODEL)")
	fs.DurationVar(&cfg.BlocklistRefresh, "blocklist-refresh", refresh, "download EasyList/EasyPrivacy at this interval, e.g. 24h; 0 disables (env ARROW_BLOCKLIST_REFRESH)")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	if fs.NArg() > 0 {
		return Config{}, fmt.Errorf("unexpected arguments: %v", fs.Args())
	}

	cfg.PublicURL = strings.TrimRight(cfg.PublicURL, "/")
	u, err := url.Parse(cfg.PublicURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return Config{}, fmt.Errorf("public URL %q must be an absolute http(s) URL", cfg.PublicURL)
	}
	if cfg.DataDir == "" {
		return Config{}, errors.New("data directory must not be empty")
	}
	if cfg.BlocklistRefresh < 0 || (cfg.BlocklistRefresh > 0 && cfg.BlocklistRefresh < time.Minute) {
		return Config{}, errors.New("blocklist refresh interval must be 0 or at least 1m")
	}
	return cfg, nil
}
