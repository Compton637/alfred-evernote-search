#!/bin/bash
# Evernote Search — Alfred Script Filter.
#
# Searches the database that the Evernote app keeps on this Mac and prints the
# matching notes as Alfred results. Nothing is sent over the network.
#
# Written for the bash that ships with macOS (3.2) and /usr/bin/sqlite3.
#
# Usage: search.sh MODE QUERY
#   MODE "all" searches titles, text, tags, notebook names and attachments;
#   MODE "titles" searches note titles only.
#
# Settings arrive as environment variables from Configure Workflow:
#   database_path       optional; a specific database file to use
#   search_attachments  1 (default) to also search text inside attachments
#   match_inside_words  1 (default) to also find a word inside longer words
#
# A word typed with a star in front (*port) is always looked for inside
# longer words, whatever that setting says.
#
# HOW THE DATABASE IS READ, AND WHAT THAT MEANS FOR THE RESULTS
#
# Evernote may write to its database at any moment. This script must never
# hold Evernote up, so it opens the file read-only and "immutable": SQLite
# then takes no locks at all. The price is that SQLite also does no
# coordination with the writer. A read that overlaps a write can fail, and it
# can also succeed with results that mix old and half-written data.
#
# To make that rare rather than silent, the script looks for Evernote's
# rollback journal (a file that exists only while a write is under way)
# before and after each read, and reads again when it saw one. If Evernote is
# still writing after a few tries, the results are shown with a notice. This
# lowers the risk; it does not remove it, because the check and the read are
# not one atomic step.
#
# Should Evernote ever switch to a write-ahead log (a "-wal" file beside the
# database), an immutable read would miss everything still in that log. In
# that mode readers and the writer do not block each other, so the script
# then opens the database as an ordinary read-only connection instead.

mode="all"
[ "$1" = "titles" ] && mode="titles"
query="$2"
SQLITE="${SQLITE3_BIN:-/usr/bin/sqlite3}"
LIMIT=40

CONTAINER_BASE="$HOME/Library/Containers/com.evernote.Evernote/Data/Library/Application Support/Evernote"
DIRECT_BASE="$HOME/Library/Application Support/Evernote"
PRIVACY_SETTINGS="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

# --- output helpers ---------------------------------------------------------

# Makes text safe inside a JSON string: control characters become spaces
# (JSON forbids them raw), then backslashes and quotes are escaped.
json_text() {
  printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' ' | tr -s ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# One non-actionable row: message TITLE SUBTITLE
message() {
  printf '{"items":[{"title":"%s","subtitle":"%s","valid":false}]}\n' "$(json_text "$1")" "$(json_text "$2")"
  exit 0
}

# One row that opens a URL when actioned: action_message TITLE SUBTITLE URL
action_message() {
  printf '{"items":[{"title":"%s","subtitle":"%s","arg":"%s"}]}\n' "$(json_text "$1")" "$(json_text "$2")" "$(json_text "$3")"
  exit 0
}

# macOS said clearly that access is not permitted.
no_access() {
  action_message "Alfred is not allowed to read Evernote's data" \
    "Press Return to open Privacy settings, then turn on Full Disk Access for Alfred" \
    "$PRIVACY_SETTINGS"
}

# The file could not be opened and the reason is not known.
cannot_open() {
  action_message "Cannot open Evernote's database" \
    "The file may have moved, or Alfred may not be allowed to read it. Press Return to open Privacy settings." \
    "$PRIVACY_SETTINGS"
}

# --- find the database ------------------------------------------------------

db=""
if [ -n "$database_path" ]; then
  case "$database_path" in
    "~/"*) db="$HOME/${database_path#\~/}" ;;
    *) db="$database_path" ;;
  esac
  [ -f "$db" ] || message "Evernote database not found" "No readable file at $db. Check the path in Configure Workflow."
else
  for base in "$CONTAINER_BASE" "$DIRECT_BASE"; do
    for candidate in "$base"/conduit-storage/*/UDB-User*+RemoteGraph.sql; do
      [ -f "$candidate" ] || continue
      # With several databases (several accounts or installations), the one
      # modified most recently is used. That is not necessarily the account
      # open in Evernote; database_path chooses a specific one.
      if [ -z "$db" ] || [ "$candidate" -nt "$db" ]; then db="$candidate"; fi
    done
  done
  if [ -z "$db" ]; then
    for base in "$CONTAINER_BASE" "$DIRECT_BASE"; do
      problem=$(LC_ALL=C ls "$base/conduit-storage" 2>&1 >/dev/null)
      case "$problem" in
        *"not permitted"* | *"ermission denied"*) no_access ;;
      esac
    done
    message "Evernote database not found" "Open Evernote on this Mac and let it finish syncing, then try again."
  fi
fi

# SQLite wants the path as a URI; this folder's name contains % signs.
encoded=$(printf '%s' "$db" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/?/%3f/g' -e 's/#/%23/g')
journal="$db-journal"
if [ -s "$db-wal" ]; then
  log_mode=1
  uri="file:$encoded?mode=ro"
else
  log_mode=0
  uri="file:$encoded?immutable=1"
fi

# --- turn the typed text into search words ----------------------------------

# Spaces and punctuation outside ASCII first become ordinary spaces, so that
# they separate words the same way a typed space does. Left in, they would
# glue two words into one phrase. This is a fixed list, not all of Unicode:
#   no-break space, « », Ogham space, U+2000 to U+200B (the typographic
#   spaces and the zero-width space), U+2010 to U+201F (hyphens, dashes and
#   curly quotes), bullet, ellipsis, line and paragraph separators, narrow
#   no-break space, medium mathematical space, ideographic space, and the
#   byte-order mark.
separators=(
  $'\xc2\xa0' $'\xc2\xab' $'\xc2\xbb' $'\xe1\x9a\x80'
  $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85'
  $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a' $'\xe2\x80\x8b'
  $'\xe2\x80\x90' $'\xe2\x80\x91' $'\xe2\x80\x92' $'\xe2\x80\x93' $'\xe2\x80\x94' $'\xe2\x80\x95'
  $'\xe2\x80\x96' $'\xe2\x80\x97' $'\xe2\x80\x98' $'\xe2\x80\x99' $'\xe2\x80\x9a' $'\xe2\x80\x9b'
  $'\xe2\x80\x9c' $'\xe2\x80\x9d' $'\xe2\x80\x9e' $'\xe2\x80\x9f'
  $'\xe2\x80\xa2' $'\xe2\x80\xa6' $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf'
  $'\xe2\x81\x9f' $'\xe3\x80\x80' $'\xef\xbb\xbf'
)
cleaned="$query"
for separator in "${separators[@]}"; do
  cleaned=${cleaned//"$separator"/ }
done

# ASCII punctuation becomes spaces too, so no word can carry quotes or other
# syntax into the search expression. Each word then matches as a prefix.
# The list is every ASCII control and punctuation character except the star,
# given as byte ranges so that accented letters (which are other bytes) pass
# untouched.
cleaned=$(printf '%s' "$cleaned" | LC_ALL=C tr '\001-\037\041-\051\053-\057\072-\100\133-\140\173-\177' ' ')

# A star in front of a word asks for that word to be found inside longer
# words. Each run of stars is moved to the start of a piece of its own, so
# "air*port" becomes "air" and "*port", and a star at the end of a word (which
# would mean "words starting with", already the normal behaviour) drops away.
cleaned=$(printf '%s' "$cleaned" | sed 's/\*\**/ */g')
set -f
pieces=($cleaned)
set +f

words=()      # the words, without stars
starred=()    # 1 for a word that was typed with a star in front, else 0
for piece in "${pieces[@]}"; do
  word="${piece#\*}"
  [ -n "$word" ] || continue
  if [ "$word" = "$piece" ]; then starred+=(0); else starred+=(1); fi
  words+=("$word")
  [ "${#words[@]}" -ge 8 ] && break
done

attachments=1
[ "$search_attachments" = "0" ] && attachments=0
[ "$mode" = "titles" ] && attachments=0
inside_words=1
[ "$match_inside_words" = "0" ] && inside_words=0

# Alfred hands over accented letters in decomposed form (a + dots instead of
# ä). The search indexes do not mind, but the inside-a-word comparison does,
# so for that the words are put back into the usual composed form.
plain_words=("${words[@]}")
if [ "${#words[@]}" -gt 0 ]; then
  composed=$(printf '%s' "${words[*]}" | iconv -f UTF-8-MAC -t UTF-8 2>/dev/null)
  if [ -n "$composed" ]; then
    set -f
    recomposed=($composed)
    set +f
    [ "${#recomposed[@]}" -eq "${#words[@]}" ] && plain_words=("${recomposed[@]}")
  fi
fi

# --- build the query --------------------------------------------------------
#
# The work is done in steps inside one sqlite3 call. Each step fills a
# temporary table (kept in memory, never written to Evernote's database):
#   inside   notes whose text has a typed word inside a longer word
#   found    the notes to show, in order
#   excerpt  for the shown notes, a few words of text around a typed word
#   me       this account's user id and shard, if there is exactly one
#   rows     the shown notes with everything worked out for display
# and the last step prints one line of Alfred JSON per note.

if [ "${#words[@]}" -eq 0 ]; then
  # Nothing typed yet: show the most recently changed notes.
  inside=""
  found="
create temp table found as
  select n.id, n.label, n.updated, n.owner, n.shardId, n.snippet, n.parent_Notebook_id,
         0 as in_title, 0 as in_body, 0 as tier
  from Nodes_Note n
  where n.deleted is null
  order by n.updated desc
  limit $LIMIT;"
  excerpt=""
  detail="found.snippet"
else
  all=""            # every word, as a search expression:  "a"* AND "b"*
  any=""            # any word:                            "a"* OR "b"*
  per_word=""
  hits=""
  title_hits=""
  body_hits=""
  inside_flags=""
  inside_where=""
  position=""
  i=0
  for word in "${words[@]}"; do
    plain="${plain_words[$i]}"
    star="${starred[$i]}"
    i=$((i + 1))
    term="\"$word\"*"
    all="${all:+$all AND }$term"
    any="${any:+$any OR }$term"

    # A word is also looked for inside longer words, so that "port" finds
    # "airport", when it was typed with a star in front, or when the setting
    # is on and the word has three or more letters. The search indexes only
    # know how words begin, so this part reads the titles and texts directly.
    within=0
    [ "$inside_words" = "1" ] && [ "${#plain}" -ge 3 ] && within=1
    [ "$star" = "1" ] && within=1
    if [ "$within" = "1" ] && [ "$mode" = "all" ]; then
      inside_flags="$inside_flags, (c.content like '%$plain%') as f$i"
      inside_where="${inside_where:+$inside_where or }c.content like '%$plain%'"
      position="${position:+$position, }nullif(instr(lower(c.content), lower('$plain')), 0)"
    else
      inside_flags="$inside_flags, 0 as f$i"
    fi

    # For each word three sets of notes are worked out:
    #   t<i>  the word is in the title
    #   b<i>  the word is in the note text
    #   w<i>  the word is anywhere that counts: title, text, tags, notebook
    #         name or (optionally) the text of an attachment
    # When only titles are searched, t<i> is all there is.
    #
    # The search indexes are asked for row numbers only, and "+x.rowid in"
    # turns those into note ids through a small index. Asking a search index
    # for the id directly makes SQLite load each note's full text, which is
    # many times slower for words that match thousands of notes.
    one="t$i(id) as (
  select n.id from Nodes_Note n where +n.rowid in (
    select rowid from Nodes_Note_FTS where Nodes_Note_FTS match 'label: $term')"
    if [ "$within" = "1" ]; then
      one="$one
  union select n.id from Nodes_Note n where n.label like '%$plain%'"
    fi
    one="$one
)"
    if [ "$mode" = "all" ]; then
      one="$one,
b$i(id) as (
  select c.id from Offline_Search_Note_Content c where +c.rowid in (
    select rowid from Offline_Search_Note_Content_FTS where Offline_Search_Note_Content_FTS match '$term')"
      if [ "$within" = "1" ]; then
        one="$one
  union select id from inside where f$i"
      fi
      one="$one
),
w$i(id) as (
  select id from t$i
  union select id from b$i
  union select nt.Note_id from Nodes_Tag_FTS tf join NoteTag nt on nt.Tag_id = tf.id where Nodes_Tag_FTS match '$term'
  union select n.id from Nodes_Notebook_FTS bf join Nodes_Note n on n.parent_Notebook_id = bf.id where Nodes_Notebook_FTS match 'label: $term'"
      if [ "$attachments" = "1" ]; then
        one="$one
  union select a.parent_Note_id from Attachment a where a.isActive = 1 and a.id in (
    select s.id from AttachmentSearchText s where +s.rowid in (
      select rowid from AttachmentSearchText_FTS where AttachmentSearchText_FTS match '$term'))"
      fi
      one="$one
)"
      hits="${hits:+$hits intersect }select id from w$i"
      body_hits="${body_hits:+$body_hits intersect }select id from b$i"
    else
      hits="${hits:+$hits intersect }select id from t$i"
    fi
    per_word="${per_word:+$per_word,
}$one"
    title_hits="${title_hits:+$title_hits intersect }select id from t$i"
  done
  [ "$mode" = "titles" ] && body_hits="select null where 0"

  # One read of the note texts answers the inside-a-word question for every
  # typed word at once.
  if [ -n "$inside_where" ]; then
    inside="
create temp table inside as
  select c.id as id$inside_flags
  from Offline_Search_Note_Content c
  where $inside_where;"
  else
    inside="
create temp table inside as select null as id$inside_flags where 0;"
  fi

  # Notes with every word in the title come first (tier 2), then notes with
  # every word in the text (tier 1), then the rest (tier 0); newest first
  # within each tier. "In the text" uses the same rules as the search itself,
  # so a word found inside a longer word counts.
  found="
create temp table found as
with
$per_word,
hits(id) as ($hits),
in_title(id) as ($title_hits),
in_body(id) as ($body_hits)
select n.id, n.label, n.updated, n.owner, n.shardId, n.snippet, n.parent_Notebook_id,
       (t.id is not null) as in_title, (b.id is not null) as in_body,
       case when t.id is not null then 2 when b.id is not null then 1 else 0 end as tier
from hits h
join Nodes_Note n on n.id = h.id
left join in_title t on t.id = n.id
left join in_body b on b.id = n.id
where n.deleted is null
order by tier desc, n.updated desc
limit $LIMIT;"

  if [ "$mode" = "titles" ]; then
    # A title search shows the start of each note.
    excerpt=""
    detail="found.snippet"
  else
    # One pass over the text index produces an excerpt for every shown note
    # whose text contains at least one of the words. Which notes are shown
    # was decided above with all words; this only picks what to display.
    excerpt="
create temp table excerpt_row as
  select c.rowid as row, c.id as id
  from Offline_Search_Note_Content c
  where c.id in (select id from found);
create temp table excerpt as
  select rowid as row, snippet(Offline_Search_Note_Content_FTS, 1, '', '', '…', 16) as words
  from Offline_Search_Note_Content_FTS
  where Offline_Search_Note_Content_FTS match '$any'
    and +rowid in (select row from excerpt_row);"

    # The third part of the subtitle shows where the words were found, taking
    # the first of these that applies: text around a word; text around a word
    # found inside a longer word; the attachment(s) containing a word; the
    # start of the note.
    detail="coalesce(
      (select e.words from excerpt e join excerpt_row r on r.row = e.row where r.id = found.id)"
    if [ -n "$position" ]; then
      detail="$detail,
      (select case when p.at > 30 then '…' else '' end || substr(p.content, max(p.at - 30, 1), 170)
       from (select c.content, coalesce($position, null) as at
             from Offline_Search_Note_Content c
             where c.id = found.id) p
       where p.at is not null)"
    fi
    if [ "$attachments" = "1" ]; then
      detail="$detail,
      (select case count(*)
                when 0 then null
                when 1 then 'In attachment' || coalesce(' ' || min(a.filename), '')
                else 'In ' || count(*) || ' attachments'
              end
       from Attachment a
       where a.parent_Note_id = found.id and a.isActive = 1 and not found.in_title
         and a.id in (
           select s.id from AttachmentSearchText s where +s.rowid in (
             select rowid from AttachmentSearchText_FTS where AttachmentSearchText_FTS match '$any')))"
    fi
    detail="$detail,
      found.snippet)"
  fi
fi

# A link needs the note's id, its owner's user id and the owner's shard. The
# owner and shard are taken together from the note; if either is missing or
# malformed, both come from this account's own record, and only when that
# record is the only one. A note without a reliable link is still shown, but
# cannot be opened from Alfred.
owner_ok="((typeof(found.owner) in ('integer', 'real') and found.owner >= 1 and found.owner = cast(found.owner as integer))
        or (typeof(found.owner) = 'text' and found.owner <> '' and found.owner not glob '*[^0-9]*' and cast(found.owner as integer) >= 1))"
shard_ok="(typeof(found.shardId) = 'text' and found.shardId <> '' and found.shardId not glob '*[^0-9A-Za-z]*')"
id_ok="(typeof(found.id) = 'text' and found.id <> '' and found.id not glob '*[^0-9A-Za-z-]*')"

sql="
pragma temp_store = memory;
$inside
$found
$excerpt
create temp table me as
  select cast(u.internal_userID as integer) as user_id, u.shardId as shard
  from Nodes_User u
  where (select count(*) from Nodes_User) = 1
    and typeof(u.internal_userID) in ('integer', 'real') and u.internal_userID >= 1
    and typeof(u.shardId) = 'text' and u.shardId <> '' and u.shardId not glob '*[^0-9A-Za-z]*';
create temp table rows as
  select found.tier, found.updated, found.id,
    case when found.label is null or trim(found.label) = '' then 'Untitled' else cast(found.label as text) end as title,
    case when $owner_ok and $shard_ok then cast(found.owner as integer) else (select user_id from me) end as user_id,
    case when $owner_ok and $shard_ok then found.shardId else (select shard from me) end as shard,
    $id_ok as id_ok,
    (select nullif(trim(nb.label), '') from Nodes_Notebook nb where nb.id = found.parent_Notebook_id) as notebook,
    case when typeof(found.updated) in ('integer', 'real') and found.updated > 0
         then strftime('%Y-%m-%d', found.updated / 1000, 'unixepoch', 'localtime') end as day,
    nullif(trim(replace(replace(replace(substr($detail, 1, 200), char(10), ' '), char(13), ' '), char(9), ' ')), '') as detail
  from found;
select
  case when id_ok and user_id is not null and shard is not null then
    json_object(
      'title', title,
      'subtitle', substr(coalesce('  ·  ' || notebook, '') || coalesce('  ·  ' || day, '') || coalesce('  ·  ' || detail, ''), 6),
      'arg', 'evernote:///view/' || user_id || '/' || shard || '/' || id || '/' || id || '/',
      'mods', json_object(
        'cmd', json_object(
          'arg', 'https://www.evernote.com/shard/' || shard || '/nl/' || user_id || '/' || id || '/',
          'subtitle', 'Open on evernote.com in the browser'),
        'alt', json_object(
          'arg', 'evernote:///view/' || user_id || '/' || shard || '/' || id || '/' || id || '/',
          'subtitle', 'Copy a link to this note')),
      'text', json_object('copy', title, 'largetype', title))
  else
    json_object(
      'title', title,
      'subtitle', substr(coalesce('  ·  ' || notebook, '') || coalesce('  ·  ' || day, '') || '  ·  No link could be made for this note', 6),
      'valid', json('false'),
      'text', json_object('copy', title, 'largetype', title))
  end
from rows
order by tier desc, updated desc;
"

# --- run it -----------------------------------------------------------------

run_query() {
  "$SQLITE" -init /dev/null -batch -readonly -list -noheader "$uri" "$sql"
}

# Reads up to three times. A read counts as settled when it worked and no
# rollback journal was there before or after it (see the top of this file).
attempt=0
unsettled=0
while :; do
  attempt=$((attempt + 1))
  unsettled=0
  [ "$log_mode" = "0" ] && [ -s "$journal" ] && unsettled=1
  out=$(run_query 2>/dev/null)
  status=$?
  [ "$log_mode" = "0" ] && [ -s "$journal" ] && unsettled=1
  [ "$status" -eq 0 ] && [ "$unsettled" = "0" ] && break
  [ "$attempt" -ge 3 ] && break
  sleep 0.15
done

if [ "$status" -ne 0 ]; then
  # Run once more to collect SQLite's own words about what went wrong.
  out=$(run_query 2>&1)
  status=$?
fi

if [ "$status" -ne 0 ]; then
  case "$out" in
    *"no such module: fts5"*)
      message "The sqlite3 on this Mac cannot search Evernote's index" \
        "This workflow needs SQLite with full-text search (FTS5), which this macOS version does not provide." ;;
    *"no such function: json"*)
      message "The sqlite3 on this Mac is too old for this workflow" \
        "This workflow needs SQLite's JSON functions, which this macOS version does not provide." ;;
    *"authorization denied"* | *"not permitted"* | *"ermission denied"*) no_access ;;
    *"unable to open database"*) cannot_open ;;
    *"no such table"* | *"no such column"* | *"no such module"*)
      message "This Evernote version stores notes differently" "The workflow needs an update: $out" ;;
    *"database is locked"* | *"malformed"* | *"disk I/O error"*)
      message "Could not read Evernote's database just now" "Evernote may be saving changes. Search again in a moment. $out" ;;
    *)
      [ "$unsettled" = "1" ] && message "Evernote is saving changes" "Search again in a moment."
      message "Evernote search did not work this time" "Try again. $out" ;;
  esac
fi

if [ -z "$out" ]; then
  [ "$unsettled" = "1" ] && message "Evernote is saving changes" "Search again in a moment."
  if [ "${#words[@]}" -eq 0 ]; then
    message "No notes found" "Evernote's database on this Mac has no notes yet."
  fi
  [ "$mode" = "titles" ] && message "No notes found" "No note title matches: $query"
  message "No notes found" "Nothing matches: $query"
fi

case "$out" in
  "{"*)
    items=$(printf '%s\n' "$out" | paste -s -d, -)
    if [ "$unsettled" = "1" ]; then
      items='{"title":"Evernote is saving changes","subtitle":"These results may be incomplete. Search again in a moment.","valid":false},'"$items"
    fi
    printf '{"items":[%s]}\n' "$items" ;;
  *) message "Evernote search did not work this time" "Unexpected answer from the database: ${out:0:200}" ;;
esac
