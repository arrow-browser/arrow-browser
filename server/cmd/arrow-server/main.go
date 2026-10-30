// Command arrow-server is the self-hostable backend for the Arrow browser.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/arrow-browser/arrow-browser/server/internal/ai"
	"github.com/arrow-browser/arrow-browser/server/internal/config"
	"github.com/arrow-browser/arrow-browser/server/internal/server"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	slog.SetDefault(logger)
	if err := run(logger); err != nil {
		if errors.Is(err, errUsage) {
			os.Exit(2)
		}
		logger.Error("fatal", "err", err)
		os.Exit(1)
	}
}

var errUsage = errors.New("usage")

func run(logger *slog.Logger) error {
	cfg, err := config.Load(os.Args[1:], os.Getenv, os.Stderr)
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return errUsage
	}

	var aiClient ai.Client
	if cfg.AnthropicAPIKey != "" {
		aiClient = ai.NewAnthropic(cfg.AnthropicAPIKey)
	} else {
		logger.Warn("ANTHROPIC_API_KEY is not set; AI endpoints will answer 503")
	}

	srv, err := server.New(cfg, version, aiClient, logger)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	srv.RunBackground(ctx)

	httpServer := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       time.Minute,
		WriteTimeout:      2 * time.Minute, // streaming handlers lift this per request
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}
	httpServer.RegisterOnShutdown(srv.Close)

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", cfg.Addr, "version", version, "dataDir", cfg.DataDir,
			"publicURL", cfg.PublicURL, "ai", aiClient != nil, "aiModel", cfg.AIModel)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	logger.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	logger.Info("stopped")
	return nil
}
