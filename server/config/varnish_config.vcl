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
    # Manually return so the default parameters won't be added to the hash
    return (lookup);
}

sub vcl_recv {
    if (req.url ~ "^/beefsteak/") {
        set req.backend_hint = martin;

        # Always use cache even if client requests fresh
        unset req.http.Cache-Control;
        unset req.http.Pragma;
        # Remove cookies
        unset req.http.Cookie;

        # Remove query parameters
        set req.url = regsub(req.url, "\?.*$", "");
        # Remove trailing slash
        set req.url = regsub(req.url, "/$", "");
        # Collapse multiple slashes into one
        set req.url = regsuball(req.url, "//+", "/");

        return (hash);
    }
    return (pass);
}

sub vcl_backend_response {
    if (beresp.status >= 200 && beresp.status < 300) {
        if (bereq.url ~ "^/beefsteak/([0-9]+)/([0-9]+)/([0-9]+)(\\..*)?$") {

            # Treat all variants as the same object
            unset beresp.http.Vary; 

            # Always gzip no matter what the client requested (won't double compress content)
            set beresp.do_gzip = true;

            # Set different cache policies depending on the zoom level
            # Match zoom 0-6
            if (bereq.url ~ "^/beefsteak/[0-6]/") {
                # Cache complex tiles for a good long while
                set beresp.ttl = 1d;
                # If martin is overwhelemed then use the cache for even longer
                set beresp.grace = 7d;
            # Match zoom 7-12
            } else if (bereq.url ~ "^/beefsteak/([7-9]|1[0-2])") {
                set beresp.ttl = 1h;
                set beresp.grace = 7d;
            # Match all other zooms
            } else {
                set beresp.ttl = 5m;
                set beresp.grace = 1d;
            }
            # Don't keep cached tiles around much after the grace period
            set beresp.keep = 5m;
            set beresp.http.Cache-Control = "public";
        }
    } else {
        # Don't cache error codes or other unexpected results
        set beresp.uncacheable = true;
    }
}

sub vcl_hit {
    if (req.url ~ "^/beefsteak/") {
        if (obj.ttl <= 0s && obj.grace > 0s) {
            set req.http.X-Cache = "GRACE-HIT";
        } else {
            set req.http.X-Cache = "HIT";
        }
    }
}

sub vcl_miss {
    if (req.url ~ "^/beefsteak/") {
        set req.http.X-Cache = "MISS";
    }
}

sub vcl_deliver {
    set resp.http.X-Cache = req.http.X-Cache;
    set resp.http.Access-Control-Allow-Origin = "*";
}

sub vcl_backend_error {
    set beresp.ttl = 30s;
    return (deliver);
}