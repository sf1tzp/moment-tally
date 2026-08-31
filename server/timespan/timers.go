package timespan

import (
	"context"

	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// Timers returns all running timers for a user
func (r *ResolverForTimeSpan) Timers(ctx context.Context) ([]*gqlmodel.TimeSpan, error) {
	user := auth.GetUser(ctx)

	var timeSpans []model.TimeSpan
	preloadTags(r.DB).
		Where("user_id = ?", user.ID).
		Where("end_user_time is null").
		Order("start_user_time DESC").
		Find(&timeSpans)

	result := []*gqlmodel.TimeSpan{}
	for _, span := range timeSpans {
		result = append(result, timeSpanToExternal(span))
	}
	return result, nil
}
