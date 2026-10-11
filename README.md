# Buskerino

Live song voting for performers. A stage screen shows the song list and a QR code; the audience scans it,
gets 3 thumbs each, and votes songs up the list. You lock in the leader when it's time to play it.

The pages are hosted on GitHub Pages and the votes live in Supabase, so phones can vote from anywhere.

| Page | Who uses it |
| --- | --- |
| `index.html` | The audience, on their phones (the QR code points here) |
| `display.html` | The audience monitor. Open it, drag it to the second screen, press F11 |
| `performer.html` | You, on the laptop. Log in to lock songs, mark them played and manage the list |

## One-time setup

### 1. Supabase

1. In your Supabase project, open **SQL Editor**, paste all of [`supabase/setup.sql`](supabase/setup.sql),
   change `you@example.com` on the last line to your email, and press **Run**.
2. **Authentication > Sign In / Providers**: turn on **Allow anonymous sign-ins** (this is how each phone
   gets its own 3 thumbs). Leave **Email** turned on.
3. **Authentication > Users > Add user**: create a user with that same email and a password
   (tick "Auto Confirm User"). That's your performer login.
4. **Project Settings > API**: copy the **Project URL** and the **anon public** key into
   [`js/config.js`](js/config.js).

### 2. GitHub Pages

**Settings > Pages**: set Source to **Deploy from a branch**, branch **main**, folder **/ (root)**, then Save.
Your site appears at `https://vonduzenstudios-create.github.io/Buskerino/` after a minute or two.

### 3. Load your songs

Open `performer.html` on the site, log in, and press **Load songs.json**.

## At a gig

- **Lock in the leader** freezes the top song: it shows as "Up next" and can't get more votes. You can also lock any song directly.
- **Mark as played** removes that song from the list and gives its thumbs back to the people who voted for it.
- **Reset votes for a new show** clears all votes and puts every song back.
- Hidden songs (the ones still being learned) don't show to the audience. Use Show/Hide to change that.

## Editing the song list

Edit [`songs.json`](songs.json) (order = starting priority, `"active": false` = hidden), push it,
then press **Load songs.json** on the performer page. Loading clears the current votes.

## How the vote limit works

Each phone signs in anonymously and gets 3 thumbs, at most one per song. The database enforces this,
so it can't be bypassed from the browser. Someone clearing their browser data can get a fresh 3,
which is fine for a busking crowd.
