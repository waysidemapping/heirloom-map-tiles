vcl 4.1;

backend martin {
    .host = "127.0.0.1";
    .port = "3000";
    .first_byte_timeout = 600s;
    .between_bytes_timeout = 600s;
    .connect_timeout = 5s;
    .max_connections = 100;
}

sub vcl_hash {
    # Serve the same content for the same endpoint regardless of the host or server address,
    # e.g. accessing `curl http://127.0.0.1/beefsteak/0/0/0` will properly warm cache for a
    # public endpoint like `http://tiles.example.com/beefsteak/0/0/0`

    hash_data(req.url);
    return (lookup);
}

sub vcl_recv {
    if (req.url ~ "^/beefsteak/") {
        set req.backend_hint = martin;
        
        # Remove query parameters
        set req.url = regsub(req.url, "\?.*$", "");
        # Remove trailing slash
        set req.url = regsub(req.url, "/$", "");
        # Collapse multiple slashes into one
        set req.url = regsuball(req.url, "//+", "/");
        # Remove cookies
        unset req.http.Cookie;

        return (hash);
    }
    return (pass);
}

sub vcl_backend_response {
    if (beresp.status >= 200 && beresp.status < 300) {
        if (bereq.url ~ "^/beefsteak/([0-9]+)/([0-9]+)/([0-9]+)(\\..*)?$") {

            # tiles are already compressed by martin, don't recompress
            set beresp.do_gzip = false;

            # set different cache policies depending on the zoom level
            # match zoom 0-5
            if (bereq.url ~ "^/beefsteak/[0-5]/") {
                # cache complex tiles for a good long while
                set beresp.ttl = 1d;
                # if martin is overwhelemed then use the cache for even longer
                set beresp.grace = 7d;
            # match zoom 6-12
            } else if (bereq.url ~ "^/beefsteak/([6-9]|1[0-2])") {
                set beresp.ttl = 1h;
                set beresp.grace = 7d;
            # match all other zooms
            } else {
                set beresp.ttl = 5m;
                set beresp.grace = 1h;
            }
            # don't keep cached tiles around much after the grace period
            set beresp.keep = 5m;
            set beresp.http.Cache-Control = "public";
        }
    } else {
        # don't cache error codes or other unexpected results
        set beresp.uncacheable = true;
    }
}

sub vcl_deliver {
    set resp.http.Access-Control-Allow-Origin = "*";
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}

sub vcl_backend_error {
    set beresp.ttl = 30s;
    return (deliver);
}