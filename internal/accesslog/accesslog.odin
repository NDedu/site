// internal/accesslog
// Logs one line per HTTP request: method, path, status, time in the handler, visitor IP
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

		method_name := http.method_string(req.line.(http.Requestline).method);
		duration := time.tick_since(start_tick);

		// Not answered yet, status is not known
		if !res.sent {
			log.infof("%s %s pending %v %s", method_name, req.url.path, duration, visitor_ip);
			return;
		}

		status_code := int(res.status);
		level := log.Level.Error if status_code >= 500 else log.Level.Info;
		log.logf(level, "%s %s %d %v %s", method_name, req.url.path, status_code, duration, visitor_ip);
	});
}
