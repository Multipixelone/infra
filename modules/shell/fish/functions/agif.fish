function agif --description 'Download a video (YouTube or direct URL) and convert to a gif for anki'
    argparse 's/start=' 'd/duration=' 'o/output=' 'r/resolution=' 'p/fps=' -- $argv
    or return

    set -l url $argv[1]
    if test -z "$url"
        echo "Usage: agif <url> [-s start_time] [-d duration_secs] [-o output.gif] [-r height_px] [-p fps]"
        return 1
    end

    set -l resolution 360
    set -l fps 15

    set -q _flag_resolution; and set resolution $_flag_resolution
    set -q _flag_fps; and set fps $_flag_fps

    # Detect direct video link vs platform URL (YouTube, Vimeo, etc.)
    set -l is_direct false
    string match -qr '\.(mp4|webm|mov|mkv|avi|m4v)(\?.*)?$' $url; and set is_direct true

    # Determine output filename
    set -l output
    if set -q _flag_output
        set output $_flag_output
    else if test $is_direct = true
        set -l basename (string replace -ra '.*/' '' $url | string replace -r '\?.*$' '' | string replace -r '\.[^.]+$' '')
        set output (string replace -ra '[^a-zA-Z0-9_\-]' '_' $basename | string replace -ra '_+' '_' | string trim -c _)".gif"
    else
        set -l title (yt-dlp --print title "$url" 2>/dev/null)
        if test -n "$title"
            set output (string replace -ra '[^a-zA-Z0-9_\-]' '_' $title | string replace -ra '_+' '_' | string trim -c _)".gif"
        else
            set output output.gif
        end
    end

    set -l time_args
    set -q _flag_start; and set -a time_args -ss $_flag_start
    set -q _flag_duration; and set -a time_args -t $_flag_duration

    set -l filter "fps=$fps,scale=-2:$resolution:flags=lanczos"

    if test $is_direct = true
        set -l ext (string replace -r '\?.*$' '' $url | string replace -r '.*\.' '')
        set -l tmpdir (mktemp -d /tmp/agif_XXXXXX)
        aria2c --dir "$tmpdir" --out "video.$ext" --quiet -x 8 "$url"
        and ffmpeg -i "$tmpdir/video.$ext" $time_args -an \
            -filter:v $filter \
            -f yuv4mpegpipe - \
            | gifski -o "$output" --fps $fps --quality 85 --lossy-quality 30 -
        rm -rf "$tmpdir"
    else
        yt-dlp --no-write-thumbnail -f 'bestvideo[ext=mp4]/bestvideo' "$url" -o - \
            | ffmpeg -i pipe: $time_args -an \
                -filter:v $filter \
                -f yuv4mpegpipe - \
            | gifski -o "$output" --fps $fps --quality 85 --lossy-quality 30 -
    end

    if test -s "$output"
        wl-copy --type image/gif < "$output"
        echo "Saved & copied: $output"
    end
end
