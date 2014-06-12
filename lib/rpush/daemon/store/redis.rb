module Rpush
  module Daemon
    module Store
      class Redis
        DEFAULT_MARK_OPTIONS = { persist: true }

        def initialize
          @redis = Modis.redis
        end

        def app(app_id)
          Rpush::Client::Redis::App.find(app_id)
        end

        def all_apps
          Rpush::Client::Redis::App.all
        end

        def deliverable_notifications(limit)
          pending_ns = Rpush::Client::Redis::Notification.absolute_pending_namespace
          retryable_ns = Rpush::Client::Redis::Notification.absolute_retryable_namespace

          retryable_results = @redis.multi do
            now = Time.now.to_i
            @redis.zrangebyscore(retryable_ns, 0, now)
            @redis.zremrangebyscore(retryable_ns, 0, now)
          end

          retryable_ids = retryable_results.first
          limit -= retryable_ids.size

          if limit > 0
            pending_results = @redis.multi do
              @redis.zrange(pending_ns, 0, limit)
              @redis.zremrangebyrank(pending_ns, 0, limit)
            end

            pending_ids = pending_results.first
          else
            pending_ids = []
          end

          ids = retryable_ids + pending_ids
          ids.map { |id| Rpush::Client::Redis::Notification.find(id) }
        end

        def mark_delivered(notification, time, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.delivered = true
          notification.delivered_at = time
          notification.save!(validate: false) if opts[:persist]
        end

        def mark_batch_delivered(notifications)
          now = Time.now
          notifications.each { |n| mark_delivered(n, now) }
        end

        def mark_failed(notification, code, description, time, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.delivered = false
          notification.delivered_at = nil
          notification.failed = true
          notification.failed_at = time
          notification.error_code = code
          notification.error_description = description
          notification.save!(validate: false) if opts[:persist]
        end

        def mark_batch_failed(notifications, code, description)
          now = Time.now
          notifications.each { |n| mark_failed(n, code, description, now) }
        end

        def mark_retryable(notification, deliver_after, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.retries += 1
          notification.deliver_after = deliver_after
          if opts[:persist]
            notification.save!(validate: false)
            namespace = Rpush::Client::Redis::Notification.absolute_retryable_namespace
            @redis.zadd(namespace, deliver_after.to_i, notification.id)
          end
        end

        def mark_batch_retryable(notifications, deliver_after)
          notifications.each { |n| mark_retryable(n, deliver_after) }
        end

        def create_apns_feedback(failed_at, device_token, app)
          Rpush::Client::Redis::Apns::Feedback.create!(failed_at: failed_at, device_token: device_token, app: app)
        end

        def create_gcm_notification(attrs, data, registration_ids, deliver_after, app) # rubocop:disable ParameterLists
          notification = Rpush::Client::Redis::Gcm::Notification.new
          create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app)
        end

        def create_adm_notification(attrs, data, registration_ids, deliver_after, app) # rubocop:disable ParameterLists
          notification = Rpush::Client::Redis::Adm::Notification.new
          create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app)
        end

        def update_app(app)
          app.save!
        end

        def update_notification(notification)
          notification.save!
        end

        def release_connection
          @redis.client.disconnect
        end

        def after_daemonize
        end

        private

        def create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app) # rubocop:disable ParameterLists
          notification.assign_attributes(attrs)
          notification.data = data
          notification.registration_ids = registration_ids
          notification.deliver_after = deliver_after
          notification.app = app
          notification.save!
          notification
        end
      end
    end
  end
end

Rpush::Daemon::Store::Interface.check(Rpush::Daemon::Store::Redis)