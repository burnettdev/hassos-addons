#!/usr/bin/env bashio

readonly CONFIG_DIR=/etc/alloy
readonly CONFIG_FILE="${CONFIG_DIR}/config.alloy"
readonly CONFIG_TEMPLATE="${CONFIG_DIR}/config.alloy.template"


if bashio::config.true 'override_config'; then
    if bashio::config.is_empty 'override_config_path'; then
        bashio::config.require 'override_config_path' "Config override is Enabled, must set override_config_path"
    fi
else
    # Add Fleet Management Configuration
    if bashio::config.true 'enable_fleet_management'; then
        bashio::config.require 'fleet_management_url' "You need to supply Fleet Management URL"
        bashio::config.require 'fleet_management_username' "You need to supply Fleet Management username"
        bashio::config.require 'fleet_management_password' "You need to supply Fleet Management password"
        bashio::config.require 'gcloud_rw_api_key' "You need to supply GCLOUD_RW_API_KEY"
        
        # Determine Fleet Management ID - use custom ID if provided, otherwise fallback to constants.hostname
        if bashio::config.has_value 'fleet_management_id'; then
            FLEET_ID="\"$(bashio::config "fleet_management_id")\""
        else
            FLEET_ID="constants.hostname"
        fi
        
        export FLEET_MANAGEMENT_CONFIG="
        remotecfg {
            url = \"$(bashio::config "fleet_management_url")\"
            basic_auth {
                username = \"$(bashio::config "fleet_management_username")\"
                password = \"$(bashio::config "fleet_management_password")\"
            }
            id             = $FLEET_ID
            poll_frequency = \"$(bashio::config "fleet_poll_frequency")\"
        }"
        
        # Export the GCLOUD_RW_API_KEY environment variable for the Alloy process
        export GCLOUD_RW_API_KEY="$(bashio::config "gcloud_rw_api_key")"
        
        # Write environment variables to file for the service to source
        echo "export GCLOUD_RW_API_KEY=\"$(bashio::config "gcloud_rw_api_key")\"" > /tmp/alloy_env
    else
        export FLEET_MANAGEMENT_CONFIG=""
    fi
    # Add Prometheus Write Endpoint
    if bashio::config.true 'enable_prometheus'; then

        bashio::config.require 'prometheus_write_endpoint' "You need to supply Prometheus write endpoint"
        EXTERNAL_LABELS=""
        RELABEL_CONFIG=""

        # Prometheus Write Endpoint
        if bashio::config.has_value 'prometheus_write_endpoint'; then
            PROMETHEUS_ENDPOINT="$(bashio::config "prometheus_write_endpoint")"
        fi

        # Servername External Label
        if bashio::config.has_value 'servername_tag'; then
            EXTERNAL_LABELS="
                    external_labels = {
                        \"servername\" = \"$(bashio::config "servername_tag")\",
                    }"
        fi

        # Relabel "instance" tag if configured
        if bashio::config.has_value 'instance_tag'; then
            RELABEL_CONFIG="
                        write_relabel_config {
                            action        = \"replace\"
                            source_labels = [\"instance\"]
                            target_label  = \"instance\"
                            replacement   = \"$(bashio::config "instance_tag")\"
                        }"
        fi
        export PROMETHEUS_CONFIG="
        prometheus.remote_write \"default\" {
            endpoint {
                url = \"$PROMETHEUS_ENDPOINT\"

                metadata_config {
                    send_interval = \"$(bashio::config "prometheus_scrape_interval")\"
                }
                $RELABEL_CONFIG
            }
            $EXTERNAL_LABELS
        }"

        ## Enable prometheus.exporter.unix
        if bashio::config.true 'enable_unix_component'; then
            export UNIX_CONFIG="
            prometheus.exporter.unix \"node_exporter\" { }
            prometheus.scrape \"unix\" {
                targets         = prometheus.exporter.unix.node_exporter.targets
                forward_to      = [prometheus.remote_write.default.receiver]
                scrape_interval = \"$(bashio::config "prometheus_scrape_interval")\"
            }"
        fi

        ## Enable prometheus.exporter.process
        if bashio::config.true 'enable_process_component'; then
            export PROCESS_CONFIG="
            prometheus.exporter.process \"process_exporter\" {
                matcher {
                        name    = \"{{.Comm}}\"
                        cmdline = [\".+\"]
                    }
            }
            prometheus.scrape \"process\" {
                targets         = prometheus.exporter.process.process_exporter.targets
                forward_to      = [prometheus.remote_write.default.receiver]
                scrape_interval = \"$(bashio::config "prometheus_scrape_interval")\"
            }"
        fi

        export ALLOY_CONFIG="
        prometheus.exporter.self \"alloy\" { }
        prometheus.scrape \"self\" {
            targets         = prometheus.exporter.self.alloy.targets
            forward_to      = [prometheus.remote_write.default.receiver]
            scrape_interval = \"$(bashio::config "prometheus_scrape_interval")\"
        }"
    fi

    # Add Loki to config if endpoint is supplied
    if bashio::config.true 'enable_loki'; then

        bashio::config.require 'loki_endpoint' "You need to supply Loki endpoint"

        if bashio::config.has_value 'servername_tag'; then
            labels="{component = \"loki.source.journal\", servername = \"$(bashio::config "servername_tag")\"}"
        else
            labels="{component = \"loki.source.journal\"}"
        fi

        if bashio::config.true 'enable_loki_syslog'; then
            syslog_config="
        loki.source.syslog \"syslog\" {
            listener {
                address  = \"0.0.0.0:5601\"
                labels   = { component = \"loki.source.syslog\", protocol = \"tcp\" }
            }
            listener {
                address  = \"0.0.0.0:5514\"
                protocol = \"udp\"
                labels   = { component = \"loki.source.syslog\", protocol = \"udp\"}
            }
            forward_to = [loki.write.endpoint.receiver]
        }"
        else
            syslog_config=""
        fi

        export LOKI_CONFIG="
        loki.relabel \"journal\" {
            forward_to = []
            rule {
                source_labels = [\"__journal__systemd_unit\"]
                target_label  = \"unit\"
            }
            rule {
                source_labels = [\"__journal__hostname\"]
                target_label  = \"nodename\"
            }
            rule {
                source_labels = [\"__journal_syslog_identifier\"]
                target_label  = \"syslog_identifier\"
            }
            rule {
                source_labels = [\"__journal_container_name\"]
                target_label  = \"container_name\"
            }
            rule {
                action = \"drop\"
                source_labels = [\"syslog_identifier\"]
                regex = \"audit\"
            }
        }
        loki.source.journal \"read\"  {
            forward_to    = [loki.write.endpoint.receiver]
            relabel_rules = loki.relabel.journal.rules
            labels        = $labels
            path          = \"/var/log/journal\"
        }
        $syslog_config
        loki.write \"endpoint\" {
            endpoint {
                url = \"$(bashio::config "loki_endpoint")\"
            }
        }"
    fi
    envsubst < $CONFIG_TEMPLATE > $CONFIG_FILE
fi
