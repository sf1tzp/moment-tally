package timespan

import (
	"context"
	"fmt"

	"momenttally.com/server/auth"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// RemoveTimeSpan removes a timespan.
func (r *ResolverForTimeSpan) RemoveTimeSpan(ctx context.Context, id int) (*gqlmodel.TimeSpan, error) {
	timeSpan := model.TimeSpan{ID: id}
	if preloadTags(r.DB).Where("user_id = ?", auth.GetUser(ctx).ID).Find(&timeSpan).RecordNotFound() {
		return nil, fmt.Errorf("timespan with id %d does not exist", timeSpan.ID)
	}

	remove := r.DB.Where(&model.TimeSpan{ID: id}).Delete(new(model.TimeSpan))
	if remove.Error != nil {
		return nil, remove.Error
	}

	// Record a tombstone so syncing devices drop their copy too (see
	// timeSpanChanges). Upsert: sqlite may reuse the id of a deleted row for
	// a later timespan, and that span's eventual deletion must not collide
	// with the stale tombstone.
	tombstone := model.TimeSpanTombstone{
		TimeSpanID:   id,
		UserID:       timeSpan.UserID,
		DeletedAtUTC: syncNow(),
	}
	r.DB.Where("time_span_id = ?", id).Delete(new(model.TimeSpanTombstone))
	if err := r.DB.Create(&tombstone).Error; err != nil {
		return nil, err
	}

	external := timeSpanToExternal(timeSpan)
	return external, nil
}
