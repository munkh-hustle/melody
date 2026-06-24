# Disbox Web - Discord Cloud Storage for Windows

A simple website that lets you upload and download files to/from Discord using webhooks, just like your Flutter mobile app.

## Features

- ✅ **Drag & Drop Upload** - Drag files directly from Windows Explorer
- ✅ **Chunked Uploads** - Large files are automatically split into 9MB chunks (same as Flutter app)
- ✅ **Download Files** - Reassembles chunked files automatically
- ✅ **File Browser** - View all your files with metadata
- ✅ **Delete Files** - Remove files from Discord storage
- ✅ **Progress Tracking** - Real-time upload/download progress
- ✅ **LocalStorage** - Webhook URL saved in browser for convenience
- ✅ **No Installation** - Works in any modern browser (Chrome, Edge, Firefox)

## How to Use on Windows

### Option 1: Open Directly in Browser (Easiest)

1. Navigate to the `web` folder in this project
2. Double-click `index.html` to open it in your default browser
3. Enter your Discord webhook URL (same one used in your Flutter app)
4. Click "Connect to Discord"
5. Start uploading/downloading files!

### Option 2: Host on GitHub Pages (Access from Anywhere)

1. Create a new repository on GitHub (or use existing one)
2. Upload the `index.html` file to the repository
3. Go to Settings → Pages
4. Enable GitHub Pages (select main branch)
5. Access your site at `https://yourusername.github.io/repository-name/`

### Option 3: Use Local Web Server

If you prefer running a local server:

```bash
# Using Python (already installed on most systems)
cd web
python -m http.server 8000

# Then open http://localhost:8000 in your browser
```

## Getting Your Discord Webhook URL

1. Open Discord and go to your server channel
2. Click the gear icon (Edit Channel)
3. Go to "Integrations" → "Webhooks"
4. Click "New Webhook"
5. Copy the webhook URL
6. Paste it in the Disbox website

## How It Works

The website uses the **exact same approach** as your Flutter app:

1. **Upload**: Files are split into 9MB chunks and uploaded as Discord attachments
2. **Metadata**: File information (name, size, chunks) is stored in Discord messages with `[DISBOX]` prefix
3. **Download**: Chunks are downloaded and reassembled into the original file
4. **Storage**: All data stays in your Discord channel - no third-party servers involved

## Compatibility

- **Windows 10/11** - Chrome, Edge, Firefox
- **Mac** - Safari, Chrome, Firefox  
- **Linux** - Chrome, Firefox
- **Mobile** - Also works on phones/tablets as backup to Flutter app

## Limitations

- Discord has a **10MB per attachment limit** (handled automatically via chunking)
- Free Discord accounts have **server storage limits**
- Maximum **100 files** displayed at once (Discord API limit)

## Security Notes

- Your webhook URL is stored **only in your browser's localStorage**
- No data is sent to any third-party servers
- All communication is directly between your browser and Discord's API
- Keep your webhook URL private - anyone with it can access your files

## Troubleshooting

### "Invalid webhook URL format"
Make sure your URL looks like: `https://discord.com/api/webhooks/123456789/abcdef...`

### "Failed to upload"
- Check your internet connection
- Verify the webhook has permission to send messages
- Ensure your Discord server hasn't reached storage limits

### Files not showing up
- Click the "Refresh" button
- Make sure you're using the same webhook URL as your Flutter app
- Check Discord channel to verify messages were created

## Development

This is a single-file static website (HTML + CSS + JavaScript). No build process required.

To modify:
1. Edit `index.html` in any text editor
2. Refresh your browser to see changes

## License

Same as your Flutter app - free to use and modify.
