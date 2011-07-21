;;;; epoll-for-hunchentoot.lisp

(in-package #:epoll-for-hunchentoot)


(defgeneric startt-listening% (acceptor)
"")

(defmethod start-listening%% ((acceptor acceptor))
  (when (acceptor-listen-socket acceptor)
    (hunchentoot-error "accptor is already listening"))
  (setf (acceptor-listen-socket acceptor)
	(usocket:socket-listen (or (acceptor-address acceptor)
				   usocket:*wildcard-host*)
			       (acceptor-port acceptor)
			       :reuseaddress t
			       :backlog (acceptor-listen-backlog acceptor)
			       :element-type '(unsigned-byte 8)))
(values))

(defun start-listening (acceptor)
  (when (acceptor-listen-socket acceptor)
    (hunchentoot-error "accptor is already listening"))
  (let ((server (iolib:make-socket :connect :passive
				   :address-family :internet
				   :type :stream
				   :ipv6 nil)))

    (format t "Created socket: ~A[fd=~A]~%" server (socket-os-fd server))

    (bind-address server 
		  (or (acceptor-address acceptor) 
			     +ipv4-unspecified+) 
		  :port port 
		  :reuse-addr t)
    (format t "Bound socket: ~A~%" server)

    (listen-on server
	       :backlog (acceptor-listen-backlog acceptor))
    (format t "Listening on socket bound to: ~A:~A~%"
            (local-host server)
            (local-port server))
    (setf (acceptor-listen-socket acceptor)
	  server))
  (values))



    ;; Set up the initial listener handler for any incoming clients
    ;; What kind of error checking do I need to do here?
    (set-io-handler *event-base*
                    (socket-os-fd server)
                    :read
                    (make-server-listener-handler server))

    ;; keep accepting connections forever.
    (handler-case
        (event-dispatch *event-base*)

      (socket-connection-reset-error ()
        (format t "Caught unexpected connection reset by peer!~%"))

      (hangup ()
        (format t "Caught unexpected hangup! Cilent closed connection on write!~%"))
      (end-of-file ()
        (format t "Caught unexpected end-of-file! Client closed connection on read!~%"))))


(defclass single-threaded-taskmaster-with-multiplexer (taskmaster)
  ()
  (:documentation "A taskmaster that runs synchronously in the thread
where the START function was invoked \(or in the case of LispWorks in
the thread started by COMM:START-UP-SERVER).  This is the simplest
possible taskmaster implementation in that its methods do nothing but
calling their acceptor \"sister\" methods - EXECUTE-ACCEPTOR calls
ACCEPT-CONNECTIONS, HANDLE-INCOMING-CONNECTION calls
PROCESS-CONNECTION."))

(defmethod execute-acceptor ((taskmaster single-threaded-taskmaster))
  (let ((server (acceptor-listen-socket (taskmaster-acceptor taskmaster))))
    ;; Set up the initial listener handler for any incoming clients
    ;; What kind of error checking do I need to do here?
    (set-io-handler *event-base*
                    (socket-os-fd server)
                    :read
                    (make-server-listener-handler server taskmaster))

    ;; keep accepting connections forever.
    (handler-case
        (event-dispatch *event-base*)

      (socket-connection-reset-error ()
        (format t "Caught unexpected connection reset by peer!~%"))

      (hangup ()
        (format t "Caught unexpected hangup! Cilent closed connection on write!~%"))
      (end-of-file ()
        (format t "Caught unexpected end-of-file! Client closed connection on read!~%")))))

(defun make-server-listener-handler (socket taskmaster)
  (lambda (fd event exception)
    ;; do a blocking accept, returning nil if no socket
    (let* ((client (accept-connection socket :wait t)))
      (when client
        (multiple-value-bind (who port)
            (remote-name client)
          (format t "Accepted a client from ~A:~A~%" who port)

	  ;;save incoming connection
          (setf (gethash `(,who ,port) *open-connections*) client)
	  
	  (set-io-handler *event-base*
			  (socket-os-fd client)
			  :read
			  (funcall make-incoming-conenction-handler client taskmaster)))))))


(defun make-incoming-connection-handler (socket taskmaster)
  (let ((disconnector (make-server-disconnector socket))
	(who (acceptor-addresss (taskmaster-acceptor tasmaster)))
	(port (acceptor-port (taskmaster-aceptor) taskmaster)))
    (lambda (fd event exception)
      (handler-case
	  (process-connection (taskmaster-acceptor taskmaster) socket)
	
	(socket-connection-reset-error ()
	  ;; Handle the client sending a reset.
	  (format t "Client ~A:~A: connection reset by peer.~%" who port)
	  (funcall disconnector who port :close))
	
	(end-of-file ()
	  ;; When we get an end of file, that doesn't necessarily
	  ;; mean the client went away, it could just mean that
	  ;; the client performed a shutdown on the write end of
	  ;; its socket and it is expecting the data stored in
	  ;; the server to be written to it.  However, if there
	  ;; is nothing left to write and our read end is closed,
	  ;; we shall consider it that the client went away and
	  ;; close the connection.
	  (format t "Client ~A:~A produced end-of-file on a read.~%"
		  who port)
	  (if (= read-index write-index)
	      (funcall disconnector who port :close)
	      (progn
		(funcall disconnector who port :read)
		(setf read-handler-registered nil)
		(setf eof-seen t))))))))
  
(defmethod handle-incoming-connection ((taskmaster single-threaded-taskmaster) socket)
  ;; in a single-threaded environment we just call PROCESS-CONNECTION
  (process-connection (taskmaster-acceptor taskmaster) socket))



(defun make-server-disconnector (socket)
  ;; When this function is called, it can be told which callback to remove, if
  ;; no callbacks are specified, all of them are removed! The socket can be
  ;; additionally told to be closed.
  (lambda (who port &rest events)
    (let ((fd (socket-os-fd socket)))
      (if (not (intersection '(:read :write :error) events))
          (remove-fd-handlers *event-base* fd :read t :write t :error t)
          (progn
            (when (member :read events)
              (remove-fd-handlers *event-base* fd :read t))
            (when (member :write events)
              (remove-fd-handlers *event-base* fd :write t))
            (when (member :error events)
              (remove-fd-handlers *event-base* fd :error t)))))
    ;; and finally if were asked to close the socket, we do so here
    (when (member :close events)
      (format t "Closing connection to ~A:~A~%" who port)
      (finish-output)
      (close socket)
      (remhash `(,who ,port) *open-connections*))))