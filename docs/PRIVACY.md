# Arrow privacy policy

Arrow is a browser you run on your Mac. It has no analytics, no telemetry and
no advertising, and The Browser Company is not involved.

## On your Mac

Your spaces, tabs, history, notes, easels, boosts and settings are stored in
`~/Library/Application Support/Arrow`. Web data (cookies, site storage, cache,
passwords saved by Chromium) stays in the Chromium profiles in the same folder.
Help ▸ Troubleshooting ▸ Reveal Arrow Data shows it.

## Requests Arrow makes on its own

- **Search suggestions** go to the search engine chosen in Preferences while
  you type in the command bar.
- **Favicons** may be fetched from Google's favicon service when a site has
  none in its page.
- **Block lists** for the ad blocker come from EasyList, or from your Arrow
  Cloud server when one is set.
- **Chrome extensions** are downloaded from the Chrome Web Store when you
  install them.

## Arrow Cloud (optional)

Nothing is sent to a server unless you set an Arrow Cloud server in
Preferences ▸ Arrow Cloud. That server is yours or someone you trust (see
`server/`). When you use it:

- **Sync** is end-to-end encrypted: spaces, pinned tabs and favorites are
  encrypted on your Mac with a key the server never sees.
- **Sharing** a space or folder publishes its titles and addresses on the
  server until you delete the share.
- **AI features** send the page text, title or file name needed for the task
  to the server, which forwards it to its model provider (Anthropic, or a local
  model). They are off until you turn them on.
- **Feedback** (Help ▸ Contact the Team) sends your message and your account
  email.
- **Updates** are checked against the server's appcast and verified with
  Arrow's signing key before they are installed.

## Contact

Open an issue at <https://github.com/arrow-browser/arrow-browser/issues>.
