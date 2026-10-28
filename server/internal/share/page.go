package share

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"html/template"
	"net/http"
	"net/url"
	"regexp"
)

const maxPageItems = 500

var shareIDPattern = regexp.MustCompile(`^[0-9A-Za-z]{10}$`)

const pageCSS = `body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;background:#f6f5f2;color:#1d1d1f}
main{max-width:640px;margin:0 auto;padding:48px 16px}
.kind{margin:0;font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:#6e6e73}
h1{margin:4px 0 4px;font-size:28px;overflow-wrap:anywhere}
.meta{margin:0 0 24px;color:#6e6e73}
ul{list-style:none;padding:0;margin:0 0 32px;background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
li{padding:12px 16px;border-top:1px solid #ececec;overflow-wrap:anywhere}
li:first-child{border-top:0}
li a{color:inherit;text-decoration:none;font-weight:500}
li span{display:block;font-size:13px;color:#6e6e73}
.open{display:inline-block;padding:10px 18px;border-radius:999px;background:#3a5cff;color:#fff;text-decoration:none;font-weight:600}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}ul{background:#2c2c2e}li{border-color:#3a3a3c}}`

// pageCSP allows exactly the inline stylesheet above and nothing else.
var pageCSP = func() string {
	sum := sha256.Sum256([]byte(pageCSS))
	return "default-src 'none'; style-src 'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) +
		"'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
}()

var pageTemplate = template.Must(template.New("share").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{{.Title}} · Arrow</title>
<style>` + pageCSS + `</style>
</head>
<body>
<main>
<p class="kind">Shared {{.Kind}}</p>
<h1>{{.Title}}</h1>
<p class="meta">by {{.Owner}} · {{.CreatedAt}}</p>
{{- if .Items}}
<ul>
{{- range .Items}}
<li><a href="{{.URL}}" rel="noopener noreferrer nofollow">{{.Title}}</a><span>{{.Host}}</span></li>
{{- end}}
</ul>
{{- end}}
<a class="open" href="{{.OpenURL}}">Open in Arrow</a>
</main>
</body>
</html>
`))

type pageItem struct {
	Title string
	URL   string
	Host  string
}

type pageData struct {
	Title     string
	Kind      string
	Owner     string
	CreatedAt string
	Items     []pageItem
	OpenURL   template.URL
}

func (s *Service) handlePage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Security-Policy", pageCSP)
	id := r.PathValue("id")
	if !shareIDPattern.MatchString(id) {
		http.Error(w, "Share not found", http.StatusNotFound)
		return
	}
	sh, ok := s.get(id)
	if !ok {
		http.Error(w, "Share not found", http.StatusNotFound)
		return
	}
	data := pageData{
		Title:     sh.Title,
		Kind:      sh.Kind,
		Owner:     s.ownerName(sh.OwnerID),
		CreatedAt: sh.CreatedAt.Format("January 2, 2006"),
		// The ID matched shareIDPattern, so it is safe in a custom-scheme URL.
		OpenURL: template.URL("arrowBrowser://share/" + id),
	}
	if sh.Kind == "space" || sh.Kind == "folder" {
		data.Items = linkItems(sh.Payload)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=60")
	_ = pageTemplate.Execute(w, data)
}

// linkItems extracts {"items":[{"title","url"}]} and keeps only http(s)
// links, so a share can never render a javascript: or data: URL.
func linkItems(payload json.RawMessage) []pageItem {
	var p struct {
		Items []struct {
			Title string `json:"title"`
			URL   string `json:"url"`
		} `json:"items"`
	}
	if json.Unmarshal(payload, &p) != nil {
		return nil
	}
	var items []pageItem
	for _, it := range p.Items {
		u, err := url.Parse(it.URL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			continue
		}
		title := it.Title
		if title == "" {
			title = u.Host
		}
		items = append(items, pageItem{Title: title, URL: u.String(), Host: u.Hostname()})
		if len(items) == maxPageItems {
			break
		}
	}
	return items
}
