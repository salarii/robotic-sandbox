#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zenoh-pico.h>

#if Z_FEATURE_SUBSCRIPTION == 1

#define MODE "client"
#define LOCATOR "tcp/10.0.0.1:7447"
#define KEYEXPR "clock"

void data_handler(z_loaned_sample_t *sample, void *arg) {
    z_view_string_t keystr;
    z_keyexpr_as_view_string(z_sample_keyexpr(sample), &keystr);

    z_owned_string_t value;
    z_bytes_to_string(z_sample_payload(sample), &value);

    printf("[ZEPHYR] Key: '%.*s' | Payload size: %d bytes\n",
           (int)z_string_len(z_loan(keystr)),
           z_string_data(z_loan(keystr)),
           (int)z_string_len(z_loan(value)));

    z_drop(z_move(value));
}

int main(void) {
    printf("[ZEPHYR] Robot controller starting...\n");
    printf("[ZEPHYR] Waiting for network...\n");
    sleep(5);

    z_owned_config_t config;
    z_config_default(&config);
    zp_config_insert(z_loan_mut(config), Z_CONFIG_MODE_KEY, MODE);
    zp_config_insert(z_loan_mut(config), Z_CONFIG_CONNECT_KEY, LOCATOR);

    printf("[ZEPHYR] Connecting to Zenoh at %s...\n", LOCATOR);
    z_owned_session_t s;
    if (z_open(&s, z_move(config), NULL) < 0) {
        printf("[ZEPHYR] ERROR: Unable to open session!\n");
        return -1;
    }
    printf("[ZEPHYR] Session opened OK\n");

    zp_start_read_task(z_loan_mut(s), NULL);
    zp_start_lease_task(z_loan_mut(s), NULL);

    printf("[ZEPHYR] Subscribing to '%s'...\n", KEYEXPR);
    z_owned_closure_sample_t callback;
    z_closure(&callback, data_handler, NULL, NULL);

    z_view_keyexpr_t ke;
    z_view_keyexpr_from_str_unchecked(&ke, KEYEXPR);

    z_owned_subscriber_t sub;
    if (z_declare_subscriber(z_loan(s), &sub, z_loan(ke), z_move(callback), NULL) < 0) {
        printf("[ZEPHYR] ERROR: Unable to declare subscriber.\n");
        return -1;
    }
    printf("[ZEPHYR] Subscribed OK! Waiting for data...\n");

    while (1) {
        sleep(1);
    }

    z_drop(z_move(sub));
    z_drop(z_move(s));
    return 0;
}

#else
int main(void) {
    printf("ERROR: Zenoh pico was compiled without Z_FEATURE_SUBSCRIPTION.\n");
    return -2;
}
#endif