(in-package roslisp)

(ros-load-message-types "roslib/Time")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The operations called by client code
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun start-ros-node (name &key (xml-rpc-port 8001) (pub-server-port 7001) 
		       (master-uri (make-uri "127.0.0.1" 11311)) &allow-other-keys)
  "Start up the ROS Node with the given name and master URI.  Reset any stored state left over from previous invocations."

  (let ((params (handle-command-line-arguments name)))

    (with-mutex (*ros-lock*)
      (sb-thread:make-thread 
       #'(lambda ()

	   (when (eq *node-status* :running) 
	     (error "Can't start node as status already equals running.  Call shutdown-ros-node first."))


	   ;; Start publication and xml-rpc servers.  The loops are to scan for a port that isn't in use.
	   (loop
	      (handler-case 
		  (progn 
		    (setf *xml-server* (start-xml-rpc-server :port xml-rpc-port))
		    (return))
		(address-in-use-error (c)
		  (declare (ignore c))
		  (ros-info "When starting xml-rpc-server, port ~a in use ... trying next one." xml-rpc-port)
		  (incf xml-rpc-port))))

	   (loop
	      (handler-case
		  (progn
		    (setq *tcp-server-hostname* (hostname)
			  *tcp-server* (ros-node-tcp-server pub-server-port))
		    (return))
		(address-in-use-error (c)
		  (declare (ignore c))
		  (ros-info "When starting TCP server for publications, port ~a in use... trying next one." pub-server-port)
		  (incf pub-server-port))))

  
	   (setq *tcp-server-port* pub-server-port
		 *broken-socket-streams* (make-hash-table :test #'eq)
		 *master-uri* master-uri
		 *service-uri* (format nil "rosrpc://~a:~a" *tcp-server-hostname* *tcp-server-port*)
		 *xml-rpc-caller-api* (format nil "http://~a:~a" (hostname) xml-rpc-port)
		 *publications* (make-hash-table :test #'equal)
		 *subscriptions* (make-hash-table :test #'equal)
		 *services* (make-hash-table :test #'equal)
		 *node-status* :running
		 )

	   ;; Finally, start the serve-event loop
	   (event-loop))
       :name "ROSLisp event loop")

      ;; There's no race condition - if this test and the following advertise call all happen before the event-loop starts,
      ;; things will just queue up
      (spin-until (eq *node-status* :running) 1))

    ;; Set params specified at command line
    (dolist (p params)
      (set-param (car p) (cdr p)))

    ;; Advertise on global rosout topic for debugging messages
    (advertise "/rosout" "roslib/Log")

    ;; Subscribe to time
    (when (member (get-param "use_sim_time" nil) '("true" 1 t) :test #'equal)
      (setq *use-sim-time* t)
      (subscribe "/time" "roslib/Time" (store-message-in *last-time*) ))))


(defmacro with-ros-node (args &rest body)
  "with-ros-node ARGS &rest BODY.  
Call start-ros-node with argument list ARGS, then execute the body.  Takes care of shutting down the ROS node if the body terminates or is interrupted.  

In addition to the start-ros-node arguments, ARGS may also include the boolean argument :spin.  If this is true, after body is executed, the node will just spin forever.

Assuming spin is not true, this call will return the return value of the final statement of body."

  (dbind (name &rest a &key spin) args
    (declare (ignorable name a))
    `(unwind-protect
	  (restart-case 
	      (progn
		(start-ros-node ,@args)
		,@body
		,@(when spin `((spin-until nil 100))))
	    (shutdown-ros-node (&optional a) (ros-info t "About to shutdown~:[~; due to condition ~:*~a~]" a)))
       (shutdown-ros-node))))


(defun shutdown-ros-node ()
  "Shutdown-ros-node.  Set the status to shutdown, close all open sockets and XML-RPC servers, and unregister all publications, subscriptions, and services with master node.  Finally, if *running-from-command-line* is true, exit lisp."
  (ros-debug t "Initiating shutdown")
  (with-mutex (*ros-lock*)
    (setf *node-status* :shutdown)
    (handler-case
	(stop-server *xml-server*)
      (error (c)
	(cerror "Continue" "Error stopping xml-rpc server: ~a" c)))
    (close-socket *tcp-server*)

    ;; Unregister from publications and subscriptions and close the sockets and kill subscription threads
    (do-hash (topic pub *publications*)
      (ros-rpc-call *master-uri* "unregisterPublisher" topic *xml-rpc-caller-api*)
      (dolist (sub (subscriber-connections pub))
	(handler-case
	    (close-socket (subscriber-socket sub))
	  (sb-int:simple-stream-error (c)
	    (ros-info t "Received stream error ~a when attempting to close socket ~a.  Skipping." c (subscriber-socket sub))))))

    (do-hash (topic sub *subscriptions*)
      (ros-rpc-call *master-uri* "unregisterSubscriber" topic *xml-rpc-caller-api*)
      (terminate-thread (topic-thread sub))

      ;; No longer need this as the subscriber thread takes care of it
      #|(dolist (pub (publisher-connections sub))
      (handler-case 
      (close-socket (publisher-socket pub))
      ((or sb-int:simple-stream-error simple-error) (c)
      (warn "received error ~a when attempting to close socket ~a.  Skipping." c (publisher-socket pub)))))|#
      )

    ;; Unregister services
    (do-hash (name s *services*)
      (let ((i (ros-rpc-call *master-uri* "unregisterService" name *service-uri*)))
	(unless (eql i 1)
	  (ros-warn t "When trying to close service ~a, ~a services were closed instead of 1" name i))))

    (ros-info "Shutdown complete")
    (when *running-from-command-line* (sb-ext:quit))))





(defun advertise (topic topic-type)
  "Set up things so that publish-on-topic may now be called with this topic"
  (with-fully-qualified-name topic
    (with-mutex (*ros-lock*)
      (when (hash-table-has-key *publications* topic)
	(error "Already publishing on ~a" topic))
  
      (ros-rpc-call *master-uri* "registerPublisher" topic topic-type *xml-rpc-caller-api*)
      (setf (gethash topic *publications*) (make-publication :pub-topic-type topic-type :subscriber-connections nil)))))



(defun publish-on-topic (topic message)
  "Send message string to all nodes who have subscribed with me to this topic"
  (with-fully-qualified-name topic

    (mvbind (publication known) (gethash topic *publications*)
      (unless known 
	(roslisp-error "Unknown topic ~a" topic))

      ;; Remove closed streams
      (setf (subscriber-connections publication)
	    (delete-if #'(lambda (sub) (not (open-stream-p (subscriber-stream sub))))
		       (subscriber-connections publication)))

      ;; Write message to each stream
      (dolist (sub (subscriber-connections publication))
	;; TODO: TCPROS has been hardcoded in
	(tcpros-write message (subscriber-stream sub))
	))))



(defun register-service-fn (service-name function service-type)
  "Postcondition: the node has set up a callback for calls to this service, and registered it with the master"
  (with-fully-qualified-name service-name
    (with-mutex (*ros-lock*)
      (let ((info (gethash service-name *services*)))
	(when info (roslisp-error "Cannot create service ~a as it already exists with info ~a" service-name info)))

      (let ((uri *service-uri*)
	    (req-class (service-request-type service-type)))
	(setf (gethash service-name *services*)
	      (make-service :callback function :name service-name :request-type-name "" :response-type-name "" :request-class req-class :md5 (string-downcase (format nil "~x" (md5sum req-class)))))
	(ros-rpc-call *master-uri* "registerService" service-name uri *xml-rpc-caller-api*)))))

(defmacro register-service (service-name service-type)
  "Register service with the given name SERVICE-NAME (a string) of type service-type (a symbol) with the master."
  `(register-service-fn ,service-name #',service-type ',service-type))
	
(defmacro def-service-callback (service-type-name (&rest args) &body body)
  "Define a service callback for SERVICE.  ARGS is a list of symbols naming particular fields of the service which will be available within the body.  Within the body, make-response will make an instance of the response object."
  (let ((req (gensym))
	(response-args (gensym))
	(response-type (gensym)))
    `(defun ,service-type-name (,req)
       (let ((,response-type (service-response-type ',service-type-name)))
	 (with-accessors ,(mapcar #'(lambda (arg) (list arg arg)) args) ,req
	   (flet ((make-response (&rest ,response-args)
		    (apply #'make-instance ,response-type ,response-args)))
	     ,@body))))))



(defun call-service (service-name service-type &rest request-args)
  ;; No locking needed for this 
  (let ((request-type (service-request-type service-type))
	(response-type (service-response-type service-type)))
    (with-fully-qualified-name service-name
      (mvbind (host port) (parse-rosrpc-uri (lookup-service service-name))
	;; No error checking: lookup service should signal an error if there are problems
	(ros-debug t "Calling service at host ~a and port ~a" host port)
	(tcpros-call-service host port service-name (apply #'make-instance request-type request-args) response-type)))))
    


(defun subscribe (topic topic-type callback &key (max-queue-length 'infty))
  "subscribe TOPIC TOPIC-TYPE CALLBACK &key MAX-QUEUE-LENGTH 

Set up subscription to TOPIC with given type.  CALLBACK will be called on the received messages in a separate thread.  MAX-QUEUE-LENGTH is the number of messages that are allowed to queue up while waiting for CALLBACK to run, and defaults to infinity. 

Can also be called on a topic that we're already subscribed to - in this case, ignore MAX-QUEUE-LENGTH, and just add this new callback function.  It will run in the existing callback thread for the topic, so that at most one callback function can be running at a time."

  (with-fully-qualified-name topic
    (with-mutex (*ros-lock*)
      
      (if (hash-table-has-key *subscriptions* topic)

	  ;; If already subscribed to topic, just add a new callback
	  (let ((sub (gethash topic *subscriptions*)))
	    (assert (equal topic-type (sub-topic-type sub)) nil "Asserted topic type ~a for new subscription to ~a did not match existing type ~a" topic-type topic (sub-topic-type sub))
	    (push callback (callbacks sub)))
	  
	  ;; Else create a new thread
	  (let ((sub (make-subscription :buffer (make-queue :max-size max-queue-length) 
					:publisher-connections nil :callbacks (list callback) :sub-topic-type topic-type)))
	    (setf (gethash topic *subscriptions*) sub
		  (topic-thread sub) (sb-thread:make-thread
				      (subscriber-thread sub)
				      :name (format nil "Subscriber thread for topic ~a" topic)))
	    (update-publishers topic (ros-rpc-call *master-uri* "registerSubscriber" topic topic-type *xml-rpc-caller-api*))
	    (values))))))


(defun get-param (key &optional (default nil default-supplied))
  (with-fully-qualified-name key
    (if (has-param key)
	(ros-rpc-call *master-uri* "getParam" key)
	(if default-supplied
	    default
	    (roslisp-error "Param ~a does not exist, and no default supplied" key)))))

(defun set-param (key val)
  (with-fully-qualified-name key
    (ros-rpc-call *master-uri* "setParam" key val)))

(defun has-param (key)
  (with-fully-qualified-name key
    (ros-rpc-call *master-uri* "hasParam" key)))

(defun delete-param (key)
  (with-fully-qualified-name key
    (ros-rpc-call *master-uri* "deleteParam" key)))
  

      


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun event-loop ()
  (loop
     ;; If node has stopped, end loop
     (unless (eq *node-status* :running) (return))

     ;; Allow the tcp server to respond to any incoming connections
     (handler-case
	 (sb-sys:serve-all-events 0)
       (simple-error (c)
	 (with-mutex (*ros-lock*)
	   (if (eq *node-status* :running)
	       (error c)
	       (progn
		 (ros-debug t "Event loop received error ~a.  Terminating, as node-status is now ~a" c *node-status*)
		 (return)))))))

  (ros-info t "Terminating ROS Node event loop"))
      

(defun subscriber-thread (sub)
  "This is the thread that takes items off the queue and performs the callback on them (as separate from the one that puts items onto the queue from the socket)"
  ;; We don't acquire *ros-lock* - the assumption is that the callback is safe to interleave with the node operations defined in the roslisp package
  (let ((q (buffer sub)))
    #'(lambda ()
	(loop
	   ;; We have to get this each time because there may be new callbacks
	   (let ((callbacks (callbacks sub)))
	     (mvbind (item exists) (dequeue-wait q)
	       (if exists
		   (dolist (callback callbacks)
		     (funcall callback item))
		   (return))))))))
	   

#|(defun topic-queue (topic)
  "Return the topic buffer, of type queue.  Should not be externally called."
  (with-fully-qualified-name topic
    (let ((sub (gethash topic *subscriptions*)))
      (if sub
	  (buffer sub)
	  (error "Unknown topic ~a" topic)))))|#


