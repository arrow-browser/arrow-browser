// Package server wires every Arrow service into one HTTP handler.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"path/filepath"

	"github.com/arrow-browser/arrow-browser/server/internal/ai"
	"github.com/arrow-browser/arrow-browser/server/internal/auth"
	"github.com/arrow-browser/arrow-browser/server/internal/blocklist"
	"github.com/arrow-browser/arrow-browser/server/internal/config"
	"github.com/arrow-browser/arrow-browser/server/internal/docsync"
	"github.com/arrow-browser/arrow-browser/server/internal/feedback"
	"github.com/arrow-browser/arrow-browser/server/internal/httpx"
	"github.com/arrow-browser/arrow-browser/server/internal/remoteconfig"
	"github.com/arrow-browser/arrow-browser/server/internal/share"
	"github.com/arrow-browser/arrow-browser/server/internal/updates"
)

// Server is the assembled application.
type Server struct {
	Handler    http.Handler
	sync       *docsync.Service
	blocklists *blocklist.Service
	cfg        config.Config
}

// New builds the server. aiClient may be nil to disable AI features; main
// passes an Anthropic client when ANTHROPIC_API_KEY is set.
func New(cfg config.Config, version string, aiClient ai.Client, logger *slog.Logger) (*Server, error) {
	dir := cfg.DataDir
	accounts, err := auth.NewService(filepath.Join(dir, "auth.json"))
	if err != nil {
		return nil, err
	}
	ownerName := func(id string) string {
		if u, ok := accounts.Lookup(id); ok {
			return u.DisplayName
		}
		return "Arrow user"
	}
	shares, err := share.NewService(filepath.Join(dir, "shares.json"), cfg.PublicURL, ownerName)
	if err != nil {
		return nil, err
	}
	syncSvc := docsync.NewService(filepath.Join(dir, "sync"))
	blocklists := blocklist.New(filepath.Join(dir, "blocklists"), cfg.PublicURL, logger)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": version})
	})
	accounts.Routes(mux)
	syncSvc.Routes(mux, accounts.Require)
	remoteconfig.New(filepath.Join(dir, "config"), aiClient != nil, logger).Routes(mux)
	blocklists.Routes(mux)
	updates.New(filepath.Join(dir, "releases", "releases.json"), cfg.PublicURL).Routes(mux)
	shares.Routes(mux, accounts.Require)
	ai.NewHandler(aiClient, cfg.AIModel, logger).Routes(mux, accounts.Require)
	feedback.New(filepath.Join(dir, "feedback")).Routes(mux, accounts.Optional)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such endpoint")
	})

	return &Server{
		Handler:    httpx.Chain(mux, httpx.Recover(logger), httpx.Log(logger), httpx.SecurityHeaders),
		sync:       syncSvc,
		blocklists: blocklists,
		cfg:        cfg,
	}, nil
}

// RunBackground starts periodic jobs until ctx ends.
func (s *Server) RunBackground(ctx context.Context) {
	if s.cfg.BlocklistRefresh > 0 {
		go s.blocklists.RunRefresher(ctx, s.cfg.BlocklistRefresh, blocklist.DefaultSources)
	}
}

// Close ends long-lived event streams so graceful shutdown can complete.
func (s *Server) Close() { s.sync.Close() }
