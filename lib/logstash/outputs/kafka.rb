require 'logstash/namespace'
require 'logstash/outputs/base'
require 'java'
require 'logstash-output-kafka_jars.rb'

# Write events to a Kafka topic. This uses the Kafka Producer API to write messages to a topic on
# the broker.
#
# Here's a compatibility matrix that shows the Kafka client versions that are compatible with each combination
# of Logstash and the Kafka output plugin: 
# 
# [options="header"]
# |==========================================================
# |Kafka Client Version |Logstash Version |Plugin Version |Why?
# |0.8       |2.0.0 - 2.x.x   |<3.0.0 |Legacy, 0.8 is still popular 
# |0.9       |2.0.0 - 2.3.x   | 3.x.x |Works with the old Ruby Event API (`event['product']['price'] = 10`)
# |0.9       |2.4.x - 5.x.x   | 4.x.x |Works with the new getter/setter APIs (`event.set('[product][price]', 10)`)
# |0.10.0.x  |2.4.x - 5.x.x   | 5.x.x |Not compatible with the <= 0.9 broker
# |==========================================================
# 
# NOTE: We recommended that you use matching Kafka client and broker versions. During upgrades, you should
# upgrade brokers before clients because brokers target backwards compatibility. For example, the 0.9 broker
# is compatible with both the 0.8 consumer and 0.9 consumer APIs, but not the other way around.
#
# This output supports connecting to Kafka over:
#
# * SSL (requires plugin version 3.0.0 or later)
# * Kerberos SASL (requires plugin version 5.1.0 or later)
#
# By default security is disabled but can be turned on as needed.
#
# The only required configuration is the topic_id. The default codec is plain,
# so events will be persisted on the broker in json format. If you select a codec of plain,
# Logstash will encode your messages with not only the message but also with a timestamp and
# hostname. If you do not want anything but your message passing through, you should make the output
# configuration something like:
# [source,ruby]
#     output {
#       kafka {
#         codec => plain {
#            format => "%{message}"
#         }
#         topic_id => "mytopic"
#       }
#     }
# For more information see http://kafka.apache.org/documentation.html#theproducer
#
# Kafka producer configuration: http://kafka.apache.org/documentation.html#newproducerconfigs
class LogStash::Outputs::Kafka < LogStash::Outputs::Base
  declare_threadsafe!

  config_name 'kafka'

  default :codec, 'plain'

  # The number of acknowledgments the producer requires the leader to have received
  # before considering a request complete.
  #
  # acks=0,   the producer will not wait for any acknowledgment from the server at all.
  # acks=1,   This will mean the leader will write the record to its local log but
  #           will respond without awaiting full acknowledgement from all followers.
  # acks=all, This means the leader will wait for the full set of in-sync replicas to acknowledge the record.
  config :acks, :validate => ["0", "1", "all"], :default => "1"
  # The producer will attempt to batch records together into fewer requests whenever multiple
  # records are being sent to the same partition. This helps performance on both the client
  # and the server. This configuration controls the default batch size in bytes.
  config :batch_size, :validate => :number, :default => 16384
  # This is for bootstrapping and the producer will only use it for getting metadata (topics,
  # partitions and replicas). The socket connections for sending the actual data will be
  # established based on the broker information returned in the metadata. The format is
  # `host1:port1,host2:port2`, and the list can be a subset of brokers or a VIP pointing to a
  # subset of brokers.
  config :bootstrap_servers, :validate => :string, :default => 'localhost:9092'
  # When our memory buffer is exhausted we must either stop accepting new
  # records (block) or throw errors. By default this setting is true and we block,
  # however in some scenarios blocking is not desirable and it is better to immediately give an error.
  config :block_on_buffer_full, :validate => :boolean, :default => true, :deprecated => "This config will be removed in a future release"
  # The total bytes of memory the producer can use to buffer records waiting to be sent to the server.
  config :buffer_memory, :validate => :number, :default => 33554432
  # The compression type for all data generated by the producer.
  # The default is none (i.e. no compression). Valid values are none, gzip, or snappy.
  config :compression_type, :validate => ["none", "gzip", "snappy", "lz4"], :default => "none"
  # The id string to pass to the server when making requests.
  # The purpose of this is to be able to track the source of requests beyond just
  # ip/port by allowing a logical application name to be included with the request
  config :client_id, :validate => :string
  # Serializer class for the key of the message
  config :key_serializer, :validate => :string, :default => 'org.apache.kafka.common.serialization.StringSerializer'
  # The producer groups together any records that arrive in between request
  # transmissions into a single batched request. Normally this occurs only under
  # load when records arrive faster than they can be sent out. However in some circumstances
  # the client may want to reduce the number of requests even under moderate load.
  # This setting accomplishes this by adding a small amount of artificial delay—that is,
  # rather than immediately sending out a record the producer will wait for up to the given delay
  # to allow other records to be sent so that the sends can be batched together.
  config :linger_ms, :validate => :number, :default => 0
  # The maximum size of a request
  config :max_request_size, :validate => :number, :default => 1048576
  # The key for the message
  config :message_key, :validate => :string
  # the timeout setting for initial metadata request to fetch topic metadata.
  config :metadata_fetch_timeout_ms, :validate => :number, :default => 60000
  # the max time in milliseconds before a metadata refresh is forced.
  config :metadata_max_age_ms, :validate => :number, :default => 300000
  # The size of the TCP receive buffer to use when reading data
  config :receive_buffer_bytes, :validate => :number, :default => 32768
  # The amount of time to wait before attempting to reconnect to a given host when a connection fails.
  config :reconnect_backoff_ms, :validate => :number, :default => 10
  # The configuration controls the maximum amount of time the client will wait
  # for the response of a request. If the response is not received before the timeout
  # elapses the client will resend the request if necessary or fail the request if
  # retries are exhausted.
  config :request_timeout_ms, :validate => :string
  # The default retry behavior is to retry until successful. To prevent data loss,
  # the use of this setting is discouraged.
  #
  # If you choose to set `retries`, a value greater than zero will cause the
  # client to only retry a fixed number of times. This will result in data loss
  # if a transient error outlasts your retry count.
  #
  # A value less than zero is a configuration error.
  config :retries, :validate => :number
  # The amount of time to wait before attempting to retry a failed produce request to a given topic partition.
  config :retry_backoff_ms, :validate => :number, :default => 100
  # The size of the TCP send buffer to use when sending data.
  config :send_buffer_bytes, :validate => :number, :default => 131072
  # Enable SSL/TLS secured communication to Kafka broker.
  config :ssl, :validate => :boolean, :default => false, :deprecated => "Use security_protocol => 'ssl'"
  # The truststore type.
  config :ssl_truststore_type, :validate => :string
  # The JKS truststore path to validate the Kafka broker's certificate.
  config :ssl_truststore_location, :validate => :path
  # The truststore password
  config :ssl_truststore_password, :validate => :password
  # The keystore type.
  config :ssl_keystore_type, :validate => :string
  # If client authentication is required, this setting stores the keystore path.
  config :ssl_keystore_location, :validate => :path
  # If client authentication is required, this setting stores the keystore password
  config :ssl_keystore_password, :validate => :password
  # The password of the private key in the key store file.
  config :ssl_key_password, :validate => :password
  # Security protocol to use, which can be either of PLAINTEXT,SSL,SASL_PLAINTEXT,SASL_SSL
  config :security_protocol, :validate => ["PLAINTEXT", "SSL", "SASL_PLAINTEXT", "SASL_SSL"], :default => "PLAINTEXT"
  # http://kafka.apache.org/documentation.html#security_sasl[SASL mechanism] used for client connections. 
  # This may be any mechanism for which a security provider is available.
  # GSSAPI is the default mechanism.
  config :sasl_mechanism, :validate => :string, :default => "GSSAPI"
  # The Kerberos principal name that Kafka broker runs as. 
  # This can be defined either in Kafka's JAAS config or in Kafka's config.
  config :sasl_kerberos_service_name, :validate => :string
  # The Java Authentication and Authorization Service (JAAS) API supplies user authentication and authorization 
  # services for Kafka. This setting provides the path to the JAAS file. Sample JAAS file for Kafka client:
  # [source,java]
  # ----------------------------------
  # KafkaClient {
  #   com.sun.security.auth.module.Krb5LoginModule required
  #   useTicketCache=true
  #   renewTicket=true
  #   serviceName="kafka";
  #   };
  # ----------------------------------
  #
  # Please note that specifying `jaas_path` and `kerberos_config` in the config file will add these 
  # to the global JVM system properties. This means if you have multiple Kafka inputs, all of them would be sharing the same 
  # `jaas_path` and `kerberos_config`. If this is not desirable, you would have to run separate instances of Logstash on 
  # different JVM instances.
  config :jaas_path, :validate => :path
  # Optional path to kerberos config file. This is krb5.conf style as detailed in https://web.mit.edu/kerberos/krb5-1.12/doc/admin/conf_files/krb5_conf.html
  config :kerberos_config, :validate => :path
  # The configuration controls the maximum amount of time the server will wait for acknowledgments
  # from followers to meet the acknowledgment requirements the producer has specified with the
  # acks configuration. If the requested number of acknowledgments are not met when the timeout
  # elapses an error will be returned. This timeout is measured on the server side and does not
  # include the network latency of the request.
  config :timeout_ms, :validate => :number, :default => 30000, :deprecated => "This config will be removed in a future release. Please use request_timeout_ms"
  # The topic to produce messages to
  config :topic_id, :validate => :string, :required => true
  # Serializer class for the value of the message
  config :value_serializer, :validate => :string, :default => 'org.apache.kafka.common.serialization.StringSerializer'

  public
  def register
    @thread_batch_map = Concurrent::Hash.new

    if !@retries.nil? 
      if @retries < 0
        raise ConfigurationError, "A negative retry count (#{@retries}) is not valid. Must be a value >= 0"
      end

      @logger.warn("Kafka output is configured with finite retry. This instructs Logstash to LOSE DATA after a set number of send attempts fails. If you do not want to lose data if Kafka is down, then you must remove the retry setting.", :retries => @retries)
    end


    @producer = create_producer
    @codec.on_event do |event, data|
      begin
        if @message_key.nil?
          record = org.apache.kafka.clients.producer.ProducerRecord.new(event.sprintf(@topic_id), data)
        else
          record = org.apache.kafka.clients.producer.ProducerRecord.new(event.sprintf(@topic_id), event.sprintf(@message_key), data)
        end
        prepare(record)
      rescue LogStash::ShutdownSignal
        @logger.debug('Kafka producer got shutdown signal')
      rescue => e
        @logger.warn('kafka producer threw exception, restarting',
                     :exception => e)
      end
    end
  end # def register

  def prepare(record)
    # This output is threadsafe, so we need to keep a batch per thread.
    @thread_batch_map[Thread.current].add(record)
  end

  def multi_receive(events)
    t = Thread.current
    if !@thread_batch_map.include?(t)
      @thread_batch_map[t] = java.util.ArrayList.new(events.size)
    end

    events.each do |event|
      break if event == LogStash::SHUTDOWN
      @codec.encode(event)
    end

    batch = @thread_batch_map[t]
    if batch.any?
      retrying_send(batch)
      batch.clear
    end
  end

  def retrying_send(batch)
    remaining = @retries;

    while batch.any?
      if !remaining.nil?
        if remaining < 0
          # TODO(sissel): Offer to DLQ? Then again, if it's a transient fault,
          # DLQing would make things worse (you dlq data that would be successful
          # after the fault is repaired)
          logger.info("Exhausted user-configured retry count when sending to Kafka. Dropping these events.",
                      :max_retries => @retries, :drop_count => batch.count)
          break
        end

        remaining -= 1
      end

      futures = batch.collect { |record| @producer.send(record) }

      failures = []
      futures.each_with_index do |future, i|
        begin
          result = future.get()
        rescue => e
          # TODO(sissel): Add metric to count failures, possibly by exception type.
          logger.debug? && logger.debug("KafkaProducer.send() failed: #{e}", :exception => e);
          failures << batch[i]
        end
      end

      # No failures? Cool. Let's move on.
      break if failures.empty?

      # Otherwise, retry with any failed transmissions
      batch = failures
      delay = 1.0 / @retry_backoff_ms
      logger.info("Sending batch to Kafka failed. Will retry after a delay.", :batch_size => batch.size,
                  :failures => failures.size, :sleep => delay);
      sleep(delay)
    end

  end

  def close
    @producer.close
  end

  private
  def create_producer
    begin
      props = java.util.Properties.new
      kafka = org.apache.kafka.clients.producer.ProducerConfig

      props.put(kafka::ACKS_CONFIG, acks)
      props.put(kafka::BATCH_SIZE_CONFIG, batch_size.to_s)
      props.put(kafka::BOOTSTRAP_SERVERS_CONFIG, bootstrap_servers)
      props.put(kafka::BUFFER_MEMORY_CONFIG, buffer_memory.to_s)
      props.put(kafka::COMPRESSION_TYPE_CONFIG, compression_type)
      props.put(kafka::CLIENT_ID_CONFIG, client_id) unless client_id.nil?
      props.put(kafka::KEY_SERIALIZER_CLASS_CONFIG, key_serializer)
      props.put(kafka::LINGER_MS_CONFIG, linger_ms.to_s)
      props.put(kafka::MAX_REQUEST_SIZE_CONFIG, max_request_size.to_s)
      props.put(kafka::RECONNECT_BACKOFF_MS_CONFIG, reconnect_backoff_ms) unless reconnect_backoff_ms.nil?
      props.put(kafka::REQUEST_TIMEOUT_MS_CONFIG, request_timeout_ms) unless request_timeout_ms.nil?
      props.put(kafka::RETRIES_CONFIG, retries.to_s) unless retries.nil?
      props.put(kafka::RETRY_BACKOFF_MS_CONFIG, retry_backoff_ms.to_s) 
      props.put(kafka::SEND_BUFFER_CONFIG, send_buffer_bytes.to_s)
      props.put(kafka::VALUE_SERIALIZER_CLASS_CONFIG, value_serializer)

      props.put("security.protocol", security_protocol) unless security_protocol.nil?

      if security_protocol == "SSL" || ssl
        set_trustore_keystore_config(props)
      elsif security_protocol == "SASL_PLAINTEXT"
        set_sasl_config(props)
      elsif security_protocol == "SASL_SSL"
        set_trustore_keystore_config(props)
        set_sasl_config(props)
      end


      org.apache.kafka.clients.producer.KafkaProducer.new(props)
    rescue => e
      logger.error("Unable to create Kafka producer from given configuration", :kafka_error_message => e)
      raise e
    end
  end

  def set_trustore_keystore_config(props)
    if ssl_truststore_location.nil?
      raise LogStash::ConfigurationError, "ssl_truststore_location must be set when SSL is enabled"
    end
    props.put("ssl.truststore.type", ssl_truststore_type) unless ssl_truststore_type.nil?
    props.put("ssl.truststore.location", ssl_truststore_location)
    props.put("ssl.truststore.password", ssl_truststore_password.value) unless ssl_truststore_password.nil?

    # Client auth stuff
    props.put("ssl.keystore.type", ssl_keystore_type) unless ssl_keystore_type.nil?
    props.put("ssl.key.password", ssl_key_password.value) unless ssl_key_password.nil?
    props.put("ssl.keystore.location", ssl_keystore_location) unless ssl_keystore_location.nil?
    props.put("ssl.keystore.password", ssl_keystore_password.value) unless ssl_keystore_password.nil?
  end

  def set_sasl_config(props)
    java.lang.System.setProperty("java.security.auth.login.config",jaas_path) unless jaas_path.nil?
    java.lang.System.setProperty("java.security.krb5.conf",kerberos_config) unless kerberos_config.nil?

    props.put("sasl.mechanism",sasl_mechanism)
    if sasl_mechanism == "GSSAPI" && sasl_kerberos_service_name.nil?
      raise LogStash::ConfigurationError, "sasl_kerberos_service_name must be specified when SASL mechanism is GSSAPI"
    end

    props.put("sasl.kerberos.service.name",sasl_kerberos_service_name) unless sasl_kerberos_service_name.nil?
  end

end #class LogStash::Outputs::Kafka
