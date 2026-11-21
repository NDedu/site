package accesslog

import "core:log"
import "core:time"
import http "../../odin-http"

handler :: proc(next_handler: ^http.Handler) -> http.Handler {
	return http.middleware_proc(next_handler, proc(self: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		start_tick := time.tick_now();

		inner_handler := self.next.(^http.Handler);
		inner_handler.handle(inner_handler, req, res);

		visitor_ip, has_ip := http.headers_get_unsafe(req.headers, "cf-connecting-ip");
		if !has_ip {
			visitor_ip = "-";
		}

		// odin-http passes HEAD requests to handlers as GET
		method_name := "HEAD" if req.is_head else http.method_string(req.line.(http.Requestline).method);
		duration := time.tick_since(start_tick);

		// The handler didn't respond, so there's no status yet
		if !res.sent {
			log.infof("%s %s pending %v %s", method_name, req.url.path, duration, visitor_ip);
			return;
		}

		status_code := int(res.status);
		level := log.Level.Error if status_code >= 500 else log.Level.Info;
		log.logf(level, "%s %s %d %v %s", method_name, req.url.path, status_code, duration, visitor_ip);
	});
}
