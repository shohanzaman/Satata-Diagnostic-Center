SATATA DIGITAL X-RAY & ECG CENTER — PWA v7

Files:
- index.html      Main application
- manifest.json   PWA manifest
- sw.js           Service worker / app-shell cache
- icons/          192px and 512px PWA icons

Deployment:
1. Upload ALL files and folders to the same HTTPS site.
2. Do not open index.html directly with file:// — service workers require HTTPS
   (localhost is also supported for development).
3. Open the site once in Chrome/Edge/Firefox.
4. Use the browser's Install App option or the in-app Install App button.

Important:
- The service worker caches the application shell only.
- Supabase authentication and database/API requests are intentionally NOT cached.
- The app therefore remains installable and can load its shell offline, while
  cloud data operations still require an internet connection.
