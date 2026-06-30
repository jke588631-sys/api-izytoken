package relay

import (
	"fmt"
	"net/http"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/dto"
	relaycommon "github.com/QuantumNous/new-api/relay/common"
	"github.com/QuantumNous/new-api/types"

	"github.com/gin-gonic/gin"
)

const contextKeyEmptyResponsePromptTokens = "empty_response_prompt_tokens"

// checkEmptyUpstreamResponse detects when upstream consumed input tokens but
// returned zero output tokens. Stores prompt_tokens in the gin context so the
// error log can include the real value, then returns a 503 error so the
// controller layer triggers a quota refund and the client knows to retry.
func checkEmptyUpstreamResponse(c *gin.Context, info *relaycommon.RelayInfo, usage *dto.Usage) *types.NewAPIError {
	if usage == nil {
		return nil
	}
	if usage.CompletionTokens == 0 && usage.OutputTokens == 0 && usage.PromptTokens > 0 {
		common.SetContextKey(c, contextKeyEmptyResponsePromptTokens, usage.PromptTokens)
		streamReason := ""
		if info.StreamStatus != nil {
			streamReason = fmt.Sprintf(" (reason=%s)", info.StreamStatus.EndReason)
		}
		return types.NewErrorWithStatusCode(
			fmt.Errorf("empty upstream stream before completion, likely upstream concurrency/rate-limit failure%s", streamReason),
			types.ErrorCodeEmptyResponse,
			http.StatusServiceUnavailable,
		)
	}
	return nil
}

// GetEmptyResponsePromptTokens reads the prompt_tokens stored by checkEmptyUpstreamResponse.
func GetEmptyResponsePromptTokens(c *gin.Context) int {
	return common.GetContextKeyInt(c, contextKeyEmptyResponsePromptTokens)
}
