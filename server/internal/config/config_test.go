package config

import (
	"io"
	"testing"
	"time"
)

func envMap(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestDefaults(t *testing.T) {
	cfg, err := Load(nil, envMap(nil), io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	want := Config{Addr: ":8787", DataDir: "./data", PublicURL: "http://localhost:8787", AIModel: "claude-opus-5-5"}
	if cfg != want {
		t.Fatalf("cfg = %+v, want %+v", cfg, want)
	}
}

func TestEnvAndFlagPrecedence(t *testing.T) {
	env := envMap(map[string]string{
		"ARROW_ADDR":              ":9000",
		"ARROW_DATA_DIR":          "/var/lib/arrow",
		"ARROW_PUBLIC_URL":        "https://arrow.example.com/",
		"ANTHROPIC_API_KEY":       "sk-test",
		"ARROW_AI_MODEL":          "claude-sonnet-5-5",
		"ARROW_BLOCKLIST_REFRESH": "12h",
	})
	cfg, err := Load([]string{"-addr", "127.0.0.1:8080", "-blocklist-refresh", "24h"}, env, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	want := Config{
		Addr:             "127.0.0.1:8080", // flag wins
		DataDir:          "/var/lib/arrow",
		PublicURL:        "https://arrow.example.com", // trailing slash trimmed
		AnthropicAPIKey:  "sk-test",
		AIModel:          "claude-sonnet-5-5",
		BlocklistRefresh: 24 * time.Hour,
	}
	if cfg != want {
		t.Fatalf("cfg = %+v, want %+v", cfg, want)
	}
}

func TestInvalid(t *testing.T) {
	tests := []struct {
		name string
		args []string
		env  map[string]string
	}{
		{"relative public url", []string{"-public-url", "arrow.example"}, nil},
		{"ftp public url", []string{"-public-url", "ftp://arrow.example"}, nil},
		{"bad env duration", nil, map[string]string{"ARROW_BLOCKLIST_REFRESH": "daily"}},
		{"too frequent refresh", []string{"-blocklist-refresh", "10s"}, nil},
		{"unknown flag", []string{"-nope"}, nil},
		{"stray argument", []string{"serve"}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := Load(tt.args, envMap(tt.env), io.Discard); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}
