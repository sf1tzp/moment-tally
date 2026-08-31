package timespan

import (
	"context"
	"fmt"

	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// StopTimeSpan sets an end date to an existing time span.
func (r *ResolverForTimeSpan) StopTimeSpan(ctx context.Context, id int, end model.Time) (*gqlmodel.TimeSpan, error) {
	old := &model.TimeSpan{ID: id}

	if preloadTags(r.DB).Where("user_id = ?", auth.GetUser(ctx).ID).Find(old).RecordNotFound() {
		return nil, fmt.Errorf("time span with id %d does not exist", id)
	}

	if old.EndUTC != nil {
		return nil, fmt.Errorf("timespan with id %d has already an end date", id)
	}

	utc := end.UTC()
	old.EndUTC = &utc
	userTime := end.OmitTimeZone()
	old.EndUserTime = &userTime
	old.UpdatedAtUTC = syncNow()
	r.DB.Where("time_span_id = ?", old.ID).Delete(new(model.TimeSpanTag))
	r.DB.Save(old)

	external := timeSpanToExternal(*old)
	return external, nil
}
