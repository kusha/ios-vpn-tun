package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/bschaatsbergen/dnsdialer"
	"github.com/google/uuid"
)

func getVKCreds(link string, dialer *dnsdialer.Dialer) (string, string, string, error) {
	doRequest := func(data string, url string) (map[string]any, error) {
		client := &http.Client{
			Timeout: 20 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        100,
				MaxIdleConnsPerHost: 100,
				IdleConnTimeout:     90 * time.Second,
				DialContext:         dialer.DialContext,
			},
		}
		defer client.CloseIdleConnections()

		req, err := http.NewRequest(http.MethodPost, url, bytes.NewBuffer([]byte(data)))
		if err != nil {
			return nil, err
		}

		req.Header.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:144.0) Gecko/20100101 Firefox/144.0")
		req.Header.Add("Content-Type", "application/x-www-form-urlencoded")

		httpResp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer func() {
			_ = httpResp.Body.Close()
		}()

		body, err := io.ReadAll(httpResp.Body)
		if err != nil {
			return nil, err
		}

		var resp map[string]any
		if err := json.Unmarshal(body, &resp); err != nil {
			return nil, err
		}

		return resp, nil
	}

	data := "client_id=6287487&token_type=messages&client_secret=QbYic1K3lEV5kTGiqlq2&version=1&app_id=6287487"
	url := "https://login.vk.ru/?act=get_anonym_token"

	resp, err := doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("request error: %w", err)
	}

	dataObj, ok := resp["data"].(map[string]any)
	if !ok {
		return "", "", "", fmt.Errorf("invalid response: missing data")
	}
	token1, ok := dataObj["access_token"].(string)
	if !ok || token1 == "" {
		return "", "", "", fmt.Errorf("invalid response: missing access_token")
	}

	data = fmt.Sprintf("vk_join_link=https://vk.com/call/join/%s&name=123&access_token=%s", link, token1)
	url = "https://api.vk.ru/method/calls.getAnonymousToken?v=5.274&client_id=6287487"

	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("request error: %w", err)
	}

	responseObj, ok := resp["response"].(map[string]any)
	if !ok {
		return "", "", "", fmt.Errorf("invalid response: missing response")
	}
	token2, ok := responseObj["token"].(string)
	if !ok || token2 == "" {
		return "", "", "", fmt.Errorf("invalid response: missing token")
	}

	data = fmt.Sprintf("%s%s%s", "session_data=%7B%22version%22%3A2%2C%22device_id%22%3A%22", uuid.New(), "%22%2C%22client_version%22%3A1.1%2C%22client_type%22%3A%22SDK_JS%22%7D&method=auth.anonymLogin&format=JSON&application_key=CGMMEJLGDIHBABABA")
	url = "https://calls.okcdn.ru/fb.do"

	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("request error: %w", err)
	}

	token3, ok := resp["session_key"].(string)
	if !ok || token3 == "" {
		return "", "", "", fmt.Errorf("invalid response: missing session_key")
	}

	data = fmt.Sprintf("joinLink=%s&isVideo=false&protocolVersion=5&anonymToken=%s&method=vchat.joinConversationByLink&format=JSON&application_key=CGMMEJLGDIHBABABA&session_key=%s", link, token2, token3)
	url = "https://calls.okcdn.ru/fb.do"

	resp, err = doRequest(data, url)
	if err != nil {
		return "", "", "", fmt.Errorf("request error: %w", err)
	}

	turnServer, ok := resp["turn_server"].(map[string]any)
	if !ok {
		return "", "", "", fmt.Errorf("invalid response: missing turn_server")
	}

	user, ok := turnServer["username"].(string)
	if !ok || user == "" {
		return "", "", "", fmt.Errorf("invalid response: missing username")
	}
	pass, ok := turnServer["credential"].(string)
	if !ok || pass == "" {
		return "", "", "", fmt.Errorf("invalid response: missing credential")
	}
	urls, ok := turnServer["urls"].([]any)
	if !ok || len(urls) == 0 {
		return "", "", "", fmt.Errorf("invalid response: missing urls")
	}

	turn, ok := urls[0].(string)
	if !ok || turn == "" {
		return "", "", "", fmt.Errorf("invalid response: invalid turn url")
	}

	clean := strings.Split(turn, "?")[0]
	address := strings.TrimPrefix(strings.TrimPrefix(clean, "turn:"), "turns:")

	return user, pass, address, nil
}
